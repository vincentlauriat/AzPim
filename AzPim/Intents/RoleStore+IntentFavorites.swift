import AzPimCore
import Foundation
import SwiftData

/// « Run favorite » (1.0 item 4): asks what the grouped favorite sheet would (`favoriteNeeds`), lists what each role
/// will send, then runs the favorite with those answers. Roles whose policy cannot be read are not sent.
extension RoleStore {
    /// The parameters of « Run favorite ». A justification given replaces each role's own; a ticket given is used
    /// only when the favorite's ticket roles are all in one tenant (a ticket never goes to another tenant).
    struct IntentFavoriteRequest: Sendable {
        var id: UUID
        var justification: String?
        var ticketSystem: String?
        var ticket: String?
    }

    /// `ask` asks for a missing justification, then a ticket system and number per tenant (nil or blank: refused).
    /// `confirm` false, or a throw, sends nothing. Returns the run's summary.
    func intentRunFavorite(_ request: IntentFavoriteRequest, allowed: Bool, ask: (IntentField) async throws -> String?,
                           confirm: (String) async throws -> Bool) async throws -> String {
        guard allowed else { throw Self.intentActivationDisabled }
        try await intentReady()
        let favorites = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        guard let favorite = favorites.first(where: { $0.id == request.id }) else {
            throw IntentFailure(message: String(localized: "This favorite no longer exists."))
        }
        if isOffline { throw IntentFailure(message: ActivationBlock.offline.message) }
        // Background policy reads: no sign-in window opens before the confirmation (such a role shows « unreadable policy »).
        let toSend = await TokenInteraction.$isBackground.withValue(true) { await favoriteRolesToSend(favorite) }
            .filter { $0.role.policyFetchedAt != nil }
        let answers = try await favoriteAnswers(for: toSend, request: request, ask: ask)
        let (lines, confirmed) = favoriteConfirmation(favorite, answers: answers)
        let text = String(localized: "Activate “\(favorite.name)”?") + "\n" + lines.joined(separator: "\n")
        guard try await confirm(text) else { throw Self.intentCancelled }
        // Exactly the roles the confirmation listed as sent, on the policies it was built from.
        return await run(favorite, fromPanel: false, answers: answers, requireKnownPolicy: true, only: confirmed)
    }

    private func favoriteAnswers(for roles: [(item: FavoriteItem, role: EligibleRole)], request: IntentFavoriteRequest,
                                 ask: (IntentField) async throws -> String?) async throws -> FavoriteAnswers {
        let needs = favoriteNeeds(roles)
        var answers = FavoriteAnswers(justification: Self.trimmed(request.justification))
        if needs.justification, answers.justification.isEmpty {
            answers.justification = try await Self.answer(ask, .justification, else: .justificationRequired)
        }
        let single = needs.ticketTenants.count == 1
        for tenant in needs.ticketTenants {
            let role = roles.map(\.role).first { $0.requiresTicket && TicketRecall.tenantKey($0.account?.tenantId ?? "") == tenant }
            let name = role?.account.map { $0.tenantName ?? $0.tenantId } ?? tenant
            var system = single ? Self.trimmed(request.ticketSystem) : ""
            if system.isEmpty { system = role.map(ticketSystem(for:)) ?? "" }
            if system.isEmpty { system = try await Self.answer(ask, .ticketSystem(tenant: name), else: .ticketSystemRequired) }
            var number = single ? Self.trimmed(request.ticket) : ""
            if number.isEmpty { number = try await Self.answer(ask, .ticketNumber(tenant: name), else: .ticketRequired) }
            answers.tickets[tenant] = FavoriteAnswers.Ticket(system: system, number: number)
        }
        if let block = FavoriteRun.block(needs, answers: answers) { throw IntentFailure(message: block.message) }
        return answers
    }

    private static func answer(_ ask: (IntentField) async throws -> String?, _ field: IntentField,
                               else block: ActivationBlock) async throws -> String {
        let answer = trimmed(try await ask(field))
        guard !answer.isEmpty else { throw IntentFailure(message: block.message) }
        return answer
    }

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `azpim://activate`: the same confirmation as « Run favorite », without answers (a role that needs a ticket, or a
    /// justification it does not have, is listed as not sent). `confirm` false sends nothing; true sends exactly the
    /// roles the confirmation listed as sent, on the policies it was built from. Nil when not confirmed.
    func linkRunFavorite(_ favorite: Favorite, confirm: (String) async -> Bool) async -> FavoriteOutcome? {
        // Same policy as the lines read (fetched if never read), in the background: no sign-in window opens before
        // the confirmation (such a role shows « unreadable policy »).
        _ = await TokenInteraction.$isBackground.withValue(true) { await favoriteRolesToSend(favorite) }
        let (lines, confirmed) = favoriteConfirmation(favorite, answers: nil)
        guard await confirm(String(localized: "A link asked AzPim to activate:") + "\n" + lines.joined(separator: "\n")) else {
            return nil
        }
        return await runFavorite(favorite, fromPanel: false, requireKnownPolicy: true, only: confirmed)
    }

    /// One line per role, with what `run` will do (the same skips and the same computed input), and the eligible role
    /// ids listed as sent. `answers` nil: what a link sends (no ticket).
    private func favoriteConfirmation(_ favorite: Favorite, answers: FavoriteAnswers?) -> (lines: [String], sent: Set<String>) {
        let active = Set(activeActivations().compactMap { $0.eligibleRole?.id })
        var sent = Set<String>()
        let lines = favorite.items.map { item in
            guard let role = favoriteRole(for: item) else {
                return "• " + String(localized: "Unknown role") + "\n   " + String(localized: "no longer eligible")
            }
            let account = Self.accountLine(role.account)
            let heading = "• \(role.displayRoleName) — \(role.displayScopeName)\n   "
            if active.contains(role.id) { return heading + String(localized: "\(account): already active") }
            if waitingRequest(for: role) != nil {
                return heading + String(localized: "\(account): skipped (already requested, waiting)")
            }
            if role.policyFetchedAt == nil {
                return heading + String(localized: "\(account): not sent (\(String(localized: "unreadable policy")))")
            }
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification,
                                     answers: answers, tenantId: role.account?.tenantId ?? "") {
            case .success(let input):
                sent.insert(role.id)
                let duration = ISODuration.label(ISODuration.seconds(input.duration) ?? 0)
                let ticket = Self.ticketText(input).map { ", \($0)" } ?? ""
                return heading + "\(account), \(duration), “\(input.justification)”\(ticket)"
            case .failure(let failure):
                return heading + String(localized: "\(account): not sent (\(failure.userMessage))")
            }
        }
        return (lines, sent)
    }
}
