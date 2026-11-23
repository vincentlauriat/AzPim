import AzPimCore
import Foundation
import UserNotifications

/// A local notification as plain values: a `UNNotificationRequest` is built only where it is added (Swift 6.1 rejects
/// sending one across actors).
struct LocalNotification: Sendable, Equatable {
    var id: String
    var title: String
    var body: String
    var sound = false
    var category: String?
    var roleId: String?
    /// Seconds from now; nil delivers at once.
    var delay: TimeInterval?
}

/// The notification center the scheduler talks to (faked in tests).
protocol NotificationCenterClient: Sendable {
    @MainActor func setUp(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>)
    func pendingIdentifiers() async -> [String]
    func removePending(withIdentifiers ids: [String])
    func removeDelivered(withIdentifiers ids: [String])
    func add(_ notification: LocalNotification) async
    /// The user lets AzPim post alerts (authorized or provisional).
    func isAuthorized() async -> Bool
}

/// `UNUserNotificationCenter.current()`, read on each call: the center itself never crosses actors.
struct SystemNotificationCenter: NotificationCenterClient {
    @MainActor func setUp(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories(categories)
    }

    func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { done in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                done.resume(returning: requests.map(\.identifier))
            }
        }
    }

    func removePending(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    func add(_ notification: LocalNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.sound { content.sound = .default }
        if let category = notification.category { content.categoryIdentifier = category }
        if let roleId = notification.roleId { content.userInfo = [NotificationScheduler.roleKey: roleId] }
        let trigger = notification.delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return [.authorized, .provisional].contains(status)
    }
}

/// Expiry Notification (T3.9, T4.1): one local notification per activation, `lead` minutes before its end,
/// with Extend / Dismiss actions. The eligible role id travels in `userInfo`: assignment rows are recreated on
/// every refresh and their instance id changes after an extension.
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "EXPIRY"
    nonisolated static let extendAction = "EXTEND"
    nonisolated static let dismissAction = "DISMISS"
    nonisolated static let prefix = "expiry-"
    nonisolated static let roleKey = "eligibleRoleId"
    /// Results of an action (activation, favorite run): never removed by `reschedule`, which only owns `prefix`.
    nonisolated static let resultPrefix = "result-"
    private let center: any NotificationCenterClient
    /// Opens the app on the notification's role (eligible role id, nil for follow-ups).
    var onOpen: ((String?) -> Void)?
    /// Runs the extension and returns the follow-up text.
    var onExtend: ((String) async -> String)?

    init(center: any NotificationCenterClient = SystemNotificationCenter()) {
        self.center = center
        super.init()
        // Changes privileges: needs an unlocked Mac (security review I1).
        let extend = UNNotificationAction(identifier: Self.extendAction, title: String(localized: "Extend"),
                                          options: [.authenticationRequired])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: String(localized: "Dismiss"), options: [.destructive])
        center.setUp(delegate: self, categories: [UNNotificationCategory(identifier: Self.category, actions: [extend, dismiss],
                                                                         intentIdentifiers: [])])
    }

    func reschedule(activations: [ActiveAssignment], leadMinutes: Int) async {
        // Decided before any `await`: the rows may be deleted meanwhile (account removed). `notifiedAt` holds the
        // planned fire date; only a date already passed means "delivered" (a lead-time change reschedules).
        let now = Date.now
        var requests: [LocalNotification] = []
        for assignment in activations {
            guard let end = assignment.endAt, end > now else { continue }
            var fireAt = end.addingTimeInterval(-Double(leadMinutes) * 60)
            if fireAt <= now {
                // Already inside the lead window (short activation, late launch): notify now, once.
                if let planned = assignment.notifiedAt, planned <= now { continue }
                fireAt = now
            }
            assignment.notifiedAt = fireAt
            let roleId = assignment.eligibleRole?.id
            let time = end.appFormatted(date: .omitted, time: .shortened), lead = ISODuration.label(Double(leadMinutes) * 60)
            requests.append(LocalNotification(
                id: Self.prefix + (roleId ?? assignment.id), title: "\(assignment.displayRoleName) — \(assignment.displayScopeName)",
                body: String(localized: "Expires at \(time) (\(lead))."), sound: true,
                category: roleId == nil ? nil : Self.category, roleId: roleId, delay: max(1, fireAt.timeIntervalSince(now))))
        }
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.prefix) }
        center.removePending(withIdentifiers: pending)
        for request in requests {
            await center.add(request)
        }
    }

    /// Immediate notification (follow-ups, approval decisions).
    func notify(title: String, body: String) async {
        await center.add(LocalNotification(id: UUID().uuidString, title: title, body: body))
    }

    /// Result of an action, posted only when notifications are allowed: false when not posted (the caller's inline
    /// status is then the only feedback, never a modal). `roleId`: a tap opens the role; `extendable` adds the
    /// Extend / Dismiss actions of the expiry notification (an activation that is now active).
    @discardableResult
    func notifyResult(title: String, body: String, roleId: String? = nil, extendable: Bool = false) async -> Bool {
        guard await center.isAuthorized() else { return false }
        await center.add(LocalNotification(id: Self.resultPrefix + UUID().uuidString, title: title, body: body,
                                           category: extendable && roleId != nil ? Self.category : nil, roleId: roleId))
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let roleId = response.notification.request.content.userInfo[Self.roleKey] as? String
        let title = response.notification.request.content.title
        switch action {
        case Self.extendAction:
            // Awaited here: the system treats the response as handled when this method returns.
            guard let roleId else { return }
            await extend(roleId: roleId, title: title)
        case Self.dismissAction, UNNotificationDismissActionIdentifier:
            break
        default:
            await MainActor.run { onOpen?(roleId) }
        }
    }

    private func extend(roleId: String, title: String) async {
        guard let onExtend else { return }
        let text = await onExtend(roleId)
        center.removeDelivered(withIdentifiers: [Self.prefix + roleId])
        await notify(title: title, body: text)
    }
}
