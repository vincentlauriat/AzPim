import AzPimCore
import Foundation

/// Keyboard-first activation (1.0 item 3): one path for the palette's Return, the panel's Return and ⌥-click.
extension RoleStore {
    enum QuickResult: Equatable {
        /// The request was sent: its status, nil when it failed (the error is on the row).
        case sent(RequestStatus?)
        /// The policy needs a justification or a ticket, or is unknown: open the Activation Sheet.
        case needsSheet
        /// Nothing sent; the reason is also on the row.
        case blocked(String)
    }

    /// Activates `role` with its default duration when its policy asks for nothing else (`QuickActivation.decide`).
    /// The policy is read first when it never was, so its defaults (justification required) never decide alone.
    func quickActivate(_ role: EligibleRole, fromPanel: Bool = true) async -> QuickResult {
        await ensurePolicy(for: role)
        let facts = QuickActivation.Facts(policy: role.policy, policyKnown: role.policyFetchedAt != nil,
                                          lastDuration: lastDuration(for: role),
                                          inProgress: busy.contains(role.id), pending: waitingRequest(for: role) != nil,
                                          offline: isOffline)
        switch QuickActivation.decide(facts) {
        case .openSheet:
            return .needsSheet
        case .blocked(let block):
            rowErrors[role.id] = block.message
            return .blocked(block.message)
        case .send(let input):
            return .sent(await activate(role, input: input, fromPanel: fromPanel))
        }
    }
}
