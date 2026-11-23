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

    enum IntentField: Sendable {
        case justification, ticket
    }

    /// The parameters of « Activate role »; `minutes` nil for the role's default duration.
    struct IntentRequest: Sendable {
        var roleId: String
        var minutes: Int?
        var justification: String?
        var ticket: String?
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
        guard let role = resolvedRole(id: request.roleId) else {
            throw IntentFailure(message: String(localized: "This role is no longer eligible."))
        }
        await ensurePolicy(for: role)
        var request = request
        var asked: Set<IntentField> = []
        while true {
            let decision = IntentActivation.decide(intentFacts(role, request, allowed: allowed))
            switch decision {
            case .needsJustification, .needsTicket:
                let field: IntentField = decision == .needsTicket ? .ticket : .justification
                let block: ActivationBlock = field == .ticket ? .ticketRequired : .justificationRequired
                guard asked.insert(field).inserted, let answer = try await ask(field) else {
                    throw IntentFailure(message: block.message)
                }
                if field == .ticket { request.ticket = answer } else { request.justification = answer }
            case .refused(let refusal):
                throw IntentFailure(message: Self.message(for: refusal, role: role))
            case .send(let input):
                guard try await confirm(intentConfirmation(role, input: input)) else { throw Self.intentCancelled }
                return try await intentSend(role, input: input)
            }
        }
    }

    private func intentFacts(_ role: EligibleRole, _ request: IntentRequest, allowed: Bool) -> IntentActivation.Facts {
        IntentActivation.Facts(allowed: allowed, policy: role.policy, policyKnown: role.policyFetchedAt != nil,
                               active: activeActivations().contains { $0.eligibleRole?.id == role.id },
                               lastDuration: lastDuration(for: role), requestedMinutes: request.minutes,
                               justification: request.justification ?? "", ticket: request.ticket ?? "",
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
        if let ticket = input.ticketNumber { lines.append(String(localized: "Ticket: \(ticket)")) }
        return lines.joined(separator: "\n")
    }

    private static func accountLine(_ account: Account?) -> String {
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

    // MARK: - Favorites

    /// « Run favorite »: the confirmation lists what each role will send (as `azpim://activate` does), then the
    /// favorite runs as from the panel (`run`). Returns the run's summary.
    func intentRunFavorite(id: UUID, allowed: Bool, confirm: (String) async throws -> Bool) async throws -> String {
        guard allowed else { throw Self.intentActivationDisabled }
        let favorites = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        guard let favorite = favorites.first(where: { $0.id == id }) else {
            throw IntentFailure(message: String(localized: "This favorite no longer exists."))
        }
        if isOffline { throw IntentFailure(message: ActivationBlock.offline.message) }
        for role in favorite.items.compactMap({ favoriteRole(for: $0) }) {
            await ensurePolicy(for: role)
        }
        let lines = favorite.items.compactMap { item -> String? in
            guard let role = favoriteRole(for: item) else { return nil }
            let account = Self.accountLine(role.account)
            let heading = "• \(role.displayRoleName) — \(role.displayScopeName)\n   "
            if waitingRequest(for: role) != nil {
                return heading + String(localized: "\(account): skipped (already requested, waiting)")
            }
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification) {
            case .success(let input):
                let duration = ISODuration.label(ISODuration.seconds(input.duration) ?? 0)
                return heading + "\(account), \(duration), “\(input.justification)”"
            case .failure(let failure):
                return heading + String(localized: "\(account): not sent (\(failure.userMessage))")
            }
        }
        let text = String(localized: "Activate “\(favorite.name)”?") + "\n" + lines.joined(separator: "\n")
        guard try await confirm(text) else { throw Self.intentCancelled }
        return await run(favorite, fromPanel: false)
    }

    // MARK: - Deactivate all

    /// « Deactivate all »: every timed activation of the accounts in use, after a confirmation listing them. Returns
    /// « 2 of 2 deactivated », with the failures.
    func intentDeactivateAll(confirm: (String) async throws -> Bool) async throws -> String {
        let targets = activeActivations().filter { $0.eligibleRole != nil }
        guard !targets.isEmpty else { return String(localized: "No active role to deactivate.") }
        let lines = targets.map { "• \($0.displayRoleName) — \($0.displayScopeName)" }
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
