import Foundation

/// What the iPhone Live Activity should show, decided without ActivityKit so the Mac test target can check it
/// (`LiveActivityController` applies the decision on iOS). One activity at most: the activated role that ends first.
enum LiveActivityPlan {
    /// An activation the activity can show (an activated role with an end date, its eligible role known).
    struct Candidate: Equatable, Sendable {
        let eligibleRoleId: String
        let roleName: String
        let scopeName: String
        let source: String
        let endAt: Date
    }

    /// What the running activity shows: its static role and its current end date and count.
    struct Shown: Equatable, Sendable {
        let eligibleRoleId: String
        let endAt: Date
        let otherActive: Int
    }

    /// The content to show: the role that ends first and how many other activations are live.
    struct Target: Equatable, Sendable {
        let role: Candidate
        let otherActive: Int
    }

    enum Decision: Equatable, Sendable {
        /// Nothing to do (already showing the right content, or nothing to show and nothing shown).
        case none
        /// No activity yet: start one.
        case start(Target)
        /// Same role, new end date or count: update the running activity.
        case update(Target)
        /// Another role ends first now: the static attributes cannot change, so end the running activity and start one.
        case replace(Target)
        /// No activation left, or the setting is off: end the running activity.
        case end
    }

    /// The activation that ends first (still live at `now`), and how many others are live. Nil when none.
    static func target(_ candidates: [Candidate], now: Date) -> Target? {
        let live = candidates.filter { $0.endAt > now }
        guard let first = live.min(by: { ($0.endAt, $0.eligibleRoleId) < ($1.endAt, $1.eligibleRoleId) }) else { return nil }
        return Target(role: first, otherActive: live.count - 1)
    }

    /// `shown`: the running activity, nil when there is none. `enabled`: the user setting. `canStart`: an activity can
    /// only be requested while the app is in the foreground (no push server); updating and ending work in the background.
    static func decide(candidates: [Candidate], shown: Shown?, enabled: Bool, canStart: Bool, now: Date) -> Decision {
        guard enabled, let target = target(candidates, now: now) else { return shown == nil ? .none : .end }
        guard let shown else { return canStart ? .start(target) : .none }
        if shown.eligibleRoleId != target.role.eligibleRoleId {
            // Without the foreground the replacement could not start: keep showing a live role rather than nothing,
            // unless the shown one is no longer among the activations (ended or deactivated).
            if canStart { return .replace(target) }
            return candidates.contains { $0.eligibleRoleId == shown.eligibleRoleId && $0.endAt > now } ? .none : .end
        }
        if shown.endAt == target.role.endAt && shown.otherActive == target.otherActive { return .none }
        return .update(target)
    }
}
