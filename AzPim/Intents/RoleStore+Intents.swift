import AzPimCore
import Foundation
import SwiftData

/// What the Shortcuts actions do (1.0 item 4), without the App Intents runtime: the intents only ask for missing
/// fields and confirm. Same rules as `azpim://activate`: activating needs the link setting on, and every request is
/// confirmed with exactly what will be sent.
extension RoleStore {
    /// A Shortcuts action that sent nothing, or whose request failed: the sentence Shortcuts shows.
    struct IntentFailure: Error, Equatable {
        let message: String
    }

    /// A field asked through Shortcuts. `tenant`: the tenant shown when a favorite asks one ticket per tenant.
    enum IntentField: Sendable, Hashable {
        case justification
        case ticketSystem(tenant: String?)
        case ticketNumber(tenant: String?)
    }

    /// The parameters of « Activate role »; `minutes` nil for the role's default duration, `ticketSystem` nil or empty
    /// for the one last used in the role's tenant.
    struct IntentRequest: Sendable {
        var roleId: String
        var minutes: Int?
        var justification: String?
        var ticketSystem: String?
        var ticket: String?

        mutating func set(_ field: IntentField, to answer: String) {
            switch field {
            case .justification: justification = answer
            case .ticketSystem: ticketSystem = answer
            case .ticketNumber: ticket = answer
            }
        }
    }

    /// A role as Shortcuts lists it: an eligible role, or one active now (same id: the eligible role's).
    struct IntentRole: Sendable, Equatable {
        let id: String
        let name: String
        let scope: String
        let account: String
        let active: Bool
        let endAt: Date?
    }

    /// Settings › Accounts › Advanced: links and Shortcuts may activate (default on).
    nonisolated static var intentActivationAllowed: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.allowLinkActivation) as? Bool ?? true
    }

    static var intentActivationDisabled: IntentFailure {
        IntentFailure(message: String(localized: """
            Activation from links and Shortcuts is turned off in AzPim › Settings › Accounts.
            """))
    }

    static var intentCancelled: IntentFailure {
        IntentFailure(message: String(localized: "Not confirmed: nothing was sent."))
    }

    /// After a cold launch by a shortcut: waits for the launch refresh (or runs one), so the lists and confirmations
    /// leave out the Azure CLI accounts a Microsoft sign-in supersedes (`loadedSources` is empty before it).
    func intentReady() async {
        for _ in 0..<600 where lastRefresh == nil {
            if isRefreshing { try? await sleep(.milliseconds(100)) } else { await refresh() }
        }
    }

    // MARK: - Roles

    /// Eligible roles not held now, then the activations, as the panel shows them (superseded accounts left out).
    func intentRoles() -> [IntentRole] {
        let accountList = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let assignments = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        let supersession = supersession(accountList)
        let model = PanelModel(accounts: accountList.filter { !supersession.isRetired($0.id) }, assignments: assignments,
                               supersession: supersession, now: .now)
        let eligible = model.eligible.map { role in
            IntentRole(id: role.id, name: role.displayRoleName, scope: role.displayScopeName,
                       account: role.account?.upn ?? "", active: false, endAt: nil)
        }
        let active = model.activations.compactMap { row -> IntentRole? in
            guard let role = row.assignment.eligibleRole else { return nil }
            return IntentRole(id: role.id, name: row.assignment.displayRoleName, scope: row.assignment.displayScopeName,
                              account: row.assignment.account?.upn ?? "", active: true, endAt: row.assignment.endAt)
        }
        var seen = Set<String>()
        return (eligible + active).filter { seen.insert($0.id).inserted }
    }

    /// Roles matching a search, best first: displayed names (« Annuaire ») and raw names both match.
    func intentRoles(matching query: String) -> [IntentRole] {
        let all = intentRoles()
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = all.map { role in
            let raw = eligibleRole(id: role.id)
            return PaletteEntry(id: role.id, kind: role.active ? .active : .eligible, name: role.name, scope: role.scope,
                                types: [raw?.roleName ?? "", raw?.scopeName ?? ""], tenant: raw?.account?.tenantName ?? "")
        }
        return QuickPalette.rank(query, entries).compactMap { byId[$0.id] }
    }

    /// « List active roles »: one line per activation, or a sentence when there is none.
    func intentActiveSummary(_ roles: [IntentRole]) -> String {
        guard !roles.isEmpty else { return String(localized: "No active role.") }
        return roles.map { role in
            IntentSummary.activeLine(name: role.name, scope: role.scope, endAt: role.endAt)
        }.joined(separator: "\n")
    }

    // MARK: - Activate

    /// « Activate role ». `ask` asks once for a field the policy requires (nil or blank: refused). `confirm` shows the
    /// request about to be sent; false, or a throw, sends nothing. Returns the result sentence.
    func intentActivate(_ request: IntentRequest, allowed: Bool, ask: (IntentField) async throws -> String?,
                        confirm: (String) async throws -> Bool) async throws -> String {
        guard allowed else { throw Self.intentActivationDisabled }
        await intentReady()
        guard let role = resolvedRole(id: request.roleId) else {
            throw IntentFailure(message: String(localized: "This role is no longer eligible."))
        }
        await ensurePolicy(for: role)
        var request = request
        if (request.ticketSystem ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.ticketSystem = ticketSystem(for: role)
        }
        var asked: Set<IntentField> = []
        while true {
            let decision = IntentActivation.decide(intentFacts(role, request, allowed: allowed))
            switch decision {
            case .needsJustification, .needsTicketSystem, .needsTicket:
                let (field, block) = Self.missingField(decision)
                guard asked.insert(field).inserted, let answer = try await ask(field) else {
                    throw IntentFailure(message: block.message)
                }
                request.set(field, to: answer)
            case .refused(let refusal):
                throw IntentFailure(message: Self.message(for: refusal, role: role))
            case .send(let input):
                guard try await confirm(intentConfirmation(role, input: input)) else { throw Self.intentCancelled }
                return try await intentSend(role, input: input)
            }
        }
    }

    private static func missingField(_ decision: IntentActivation) -> (IntentField, ActivationBlock) {
        switch decision {
        case .needsTicketSystem: (.ticketSystem(tenant: nil), .ticketSystemRequired)
        case .needsTicket: (.ticketNumber(tenant: nil), .ticketRequired)
        default: (.justification, .justificationRequired)
        }
    }

    private func intentFacts(_ role: EligibleRole, _ request: IntentRequest, allowed: Bool) -> IntentActivation.Facts {
        IntentActivation.Facts(allowed: allowed, policy: role.policy, policyKnown: role.policyFetchedAt != nil,
                               active: activeActivations().contains { $0.eligibleRole?.id == role.id },
                               lastDuration: lastDuration(for: role), requestedMinutes: request.minutes,
                               justification: request.justification ?? "", ticketSystem: request.ticketSystem ?? "",
                               ticket: request.ticket ?? "",
                               inProgress: busy.contains(role.id),
                               pending: waitingRequest(for: role) != nil, offline: isOffline)
    }

    private func intentSend(_ role: EligibleRole, input: ActivationInput) async throws -> String {
        let name = role.displayRoleName, roleId = role.id
        let status = await activate(role, input: input, fromPanel: false)
        switch status {
        case .provisioned?:
            let end = Date.now.addingTimeInterval(ISODuration.seconds(input.duration) ?? 0)
            return String(localized: "\(name) is active until \(end.appFormatted(date: .omitted, time: .shortened)).")
        case .pendingApproval?:
            return String(localized: "\(name): the request is waiting for approval.")
        case .sent?:
            return String(localized: "\(name): the request was sent, not confirmed yet.")
        default:
            throw IntentFailure(message: rowErrors[roleId] ?? lastActivationError[roleId]?.text
                                ?? String(localized: "unknown error"))
        }
    }

    /// Everything the request sends: role, scope, account and tenant, duration, justification, ticket.
    func intentConfirmation(_ role: EligibleRole, input: ActivationInput) -> String {
        var lines = [String(localized: "Activate \(role.displayRoleName) on \(role.displayScopeName)?"),
                     Self.accountLine(role.account)]
        let duration = ISODuration.label(ISODuration.seconds(input.duration) ?? 0)
        lines.append(String(localized: "Duration: \(duration)"))
        if !input.justification.isEmpty { lines.append(String(localized: "Justification: “\(input.justification)”")) }
        if let ticket = Self.ticketText(input) { lines.append(ticket) }
        return lines.joined(separator: "\n")
    }

    /// « Ticket: Jira INC-1 », nil without a ticket.
    static func ticketText(_ input: ActivationInput) -> String? {
        guard let number = input.ticketNumber else { return nil }
        let ticket = [input.ticketSystem ?? "", number].filter { !$0.isEmpty }.joined(separator: " ")
        return String(localized: "Ticket: \(ticket)")
    }

    static func accountLine(_ account: Account?) -> String {
        account.map { String(localized: "\($0.upn) (tenant \($0.tenantName ?? $0.tenantId))") }
            ?? String(localized: "unknown account")
    }

    private static func message(for refusal: IntentActivation.Refusal, role: EligibleRole) -> String {
        switch refusal {
        case .disabled: intentActivationDisabled.message
        case .alreadyActive: String(localized: "\(role.displayRoleName) is already active.")
        case .unknownPolicy: String(localized: "Couldn't read the role's policy: nothing was sent. Try again in a moment.")
        case .blocked(let block): block.message
        }
    }

    // MARK: - Deactivate all

    /// « Deactivate all »: every timed activation of the accounts in use (only those of `ids`, eligible role ids, when
    /// given), after a confirmation listing them (with their account and tenant). Not gated by the link setting: it
    /// only removes access. Returns « 2 of 2 deactivated », with the failures.
    func intentDeactivateAll(only ids: Set<String>? = nil, confirm: (String) async throws -> Bool) async throws -> String {
        await intentReady()
        let targets = activeActivations().filter { row in
            row.eligibleRole.map { ids?.contains($0.id) != false } == true
        }
        guard !targets.isEmpty else { return String(localized: "No active role to deactivate.") }
        let lines = targets.map { "• \($0.displayRoleName) — \($0.displayScopeName)\n   \(Self.accountLine($0.account))" }
        let text = String(localized: "Deactivate these roles?") + "\n" + lines.joined(separator: "\n")
        guard try await confirm(text) else { throw Self.intentCancelled }
        var results: [IntentSummary.Deactivation] = []
        for assignment in targets {
            // Copies: a refresh may delete the row while its request runs.
            let name = assignment.displayRoleName, rowId = assignment.id
            let done = await deactivate(assignment, refreshAfter: false)
            results.append(.init(name: name, error: done ? nil : rowErrors[rowId] ?? String(localized: "failed")))
        }
        await refresh()
        return IntentSummary.deactivated(results)
    }
}
