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
    /// `held`: eligible role ids being extended or extended moments ago. An Extend deactivates, then activates again,
    /// and Azure may list the new activation a little later: meanwhile the shown role is kept, not ended (once ended,
    /// the activity could not come back from the background).
    static func decide(candidates: [Candidate], shown: Shown?, enabled: Bool, canStart: Bool, now: Date,
                       held: Set<String> = []) -> Decision {
        let live = candidates.filter { $0.endAt > now }
        if enabled, let shown, held.contains(shown.eligibleRoleId),
           !live.contains(where: { $0.eligibleRoleId == shown.eligibleRoleId }) {
            return .none
        }
        guard enabled, let target = target(candidates, now: now) else { return shown == nil ? .none : .end }
        guard let shown else { return canStart ? .start(target) : .none }
        if shown.eligibleRoleId != target.role.eligibleRoleId {
            if canStart { return .replace(target) }
            // Without the foreground the replacement could not start: keep the shown role while it is live, with its
            // own new end and count (after an Extend that ended once AzPim left the foreground, it ends later than
            // another role now), or end the activity when the shown role is no longer active.
            guard let kept = live.first(where: { $0.eligibleRoleId == shown.eligibleRoleId }) else { return .end }
            return refresh(shown, to: Target(role: kept, otherActive: live.count - 1))
        }
        return refresh(shown, to: target)
    }

    private static func refresh(_ shown: Shown, to target: Target) -> Decision {
        shown.endAt == target.role.endAt && shown.otherActive == target.otherActive ? .none : .update(target)
    }
}
