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

/// What a favorite run did, role by role (`RoleStore.runFavorite`).
struct FavoriteOutcome: Equatable {
    /// Full summary (toast, dialog): may hold Azure's error text, never put in a notification.
    var text: String
    var results: [FavoriteRoleResult]
    /// The favorite was already running: nothing was sent.
    var alreadyRunning = false

    var isFullSuccess: Bool { !alreadyRunning && !results.isEmpty && results.allSatisfy(\.succeeded) }

    /// Counts only, for a notification (« Activated: 2 of 3, failed: 1 — open AzPim. »).
    var notificationBody: String {
        let activated = results.filter { $0.status == .provisioned }.count
        let waiting = results.filter { $0.succeeded && $0.status != .provisioned }.count
        let failed = results.filter { !$0.succeeded }.count
        var text = String(localized: "Activated: \(activated) of \(results.count)")
        if waiting > 0 { text += String(localized: ", waiting: \(waiting)") }
        if failed > 0 { text += String(localized: ", failed: \(failed) — open AzPim") }
        return text + "."
    }
}

extension RoleStore {
    /// Sets the inline status, then posts the notification if allowed. Returns whether a notification was posted.
    @discardableResult
    func announce(title: String, body: String, roleId: String? = nil) async -> Bool {
        lastResult = ActionResult(title: title, body: body, roleId: roleId, date: .now)
        let posted = await notifications.notifyResult(title: title, body: body, roleId: roleId)
        // No banner to read: VoiceOver says it (the inline status does not move the focus).
        if !posted { VoiceOverAnnouncer.post("\(title). \(body)") }
        return posted
    }

    /// A favorite's result: the favorite's toast is its inline status (no second line in the panel); the notification
    /// carries the counts only.
    @discardableResult
    func announce(favorite name: String, _ outcome: FavoriteOutcome) async -> Bool {
        let posted = await notifications.notifyResult(title: name, body: outcome.notificationBody)
        if !posted { VoiceOverAnnouncer.post("\(name). \(outcome.text)") }
        return posted
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
        await announce(title: "\(role.displayRoleName) — \(role.displayScopeName)", body: body, roleId: role.id)
    }
}
