import AzPimCore
import Foundation

/// The result of an action the user started (Activation Sheet, grouped favorite sheet, link): a notification when
/// notifications are allowed, and always an inline status in the panel and the Roles Window. Never a modal: those stay
/// for confirmations and errors that need a decision (1.0 item 9).
struct ActionResult: Equatable {
    var title: String
    var body: String
    /// The eligible role it is about (the Roles Window shows it on that role), nil for a favorite.
    var roleId: String?
    var date: Date

    /// Shown inline for 10 minutes: long enough to be seen when no notification was posted.
    func isRecent(at now: Date) -> Bool { now.timeIntervalSince(date) < 600 }
}

extension RoleStore {
    /// Sets the inline status, then posts the notification if allowed. Returns whether a notification was posted.
    @discardableResult
    func announce(title: String, body: String, roleId: String? = nil, extendable: Bool = false) async -> Bool {
        lastResult = ActionResult(title: title, body: body, roleId: roleId, date: .now)
        return await notifications.notifyResult(title: title, body: body, roleId: roleId, extendable: extendable)
    }

    /// Announces an activation Azure accepted (`status` from `activate`). A refusal is not announced: it stays on
    /// the sheet, where the user can correct the request.
    func announceActivation(of role: EligibleRole, status: RequestStatus, input: ActivationInput) async {
        let body: String
        switch status {
        case .provisioned:
            let end = Date.now.addingTimeInterval(ISODuration.seconds(input.duration) ?? 0)
            body = String(localized: "Active until \(end.appFormatted(date: .omitted, time: .shortened)).")
        case .pendingApproval:
            body = String(localized: "Request sent — pending approval.")
        default:
            body = String(localized: "Request sent — not confirmed yet. Check the panel in a moment.")
        }
        await announce(title: "\(role.displayRoleName) — \(role.displayScopeName)", body: body, roleId: role.id,
                       extendable: status == .provisioned)
    }
}
