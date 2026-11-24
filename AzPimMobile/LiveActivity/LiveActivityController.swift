import ActivityKit
import AzPimCore
import Foundation
import SwiftData
import UIKit

/// Starts, updates or ends the one Live Activity of the activated role that ends first (2.0 step 4a), after every
/// store refresh (activation, Extend, deactivation, expiry and timer refreshes all end with one) and when the app comes
/// to the foreground. The decision is `LiveActivityPlan`'s (tested on Mac).
///
/// No push server: an activity is only *started* while AzPim is in the foreground (ActivityKit refuses a background
/// request without a push token); it can be updated or ended from the background (an Extend from the activity runs
/// in the app's process). A role activated on another device appears when AzPim is next opened.
@MainActor
@Observable
final class LiveActivityController {
    /// Settings › Live Activity (on by default). A user preference of this iPhone, not part of the synced data model.
    static let enabledKey = "liveActivityEnabled"

    @ObservationIgnored private let store: RoleStore
    @ObservationIgnored private let defaults: UserDefaults

    init(store: RoleStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        followRefreshes()
    }

    /// Every refresh sets `lastRefresh` once its activations are stored; the sync runs right after (next main-actor turn).
    private func followRefreshes() {
        withObservationTracking { _ = store.lastRefresh } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.followRefreshes()
            }
        }
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Activities being ended (the end is asynchronous): a sync meanwhile must not keep one of them.
    @ObservationIgnored private var ending: Set<String> = []
    /// An Extend made within this window still holds its role (Azure may list the new activation late).
    private static let extendGrace: TimeInterval = 300

    #if DEBUG
    /// Demo mode: only `AZPIM_DEMO=liveactivity` shows the activity, the other screens leave the system's alone.
    @ObservationIgnored var demoAllowed = true
    #endif

    /// Brings the activity in line with the store's activations.
    func sync() {
        #if DEBUG
        guard demoAllowed else { return }   // other demo screens leave the system's activities alone
        #endif
        let candidates = store.activeActivations().compactMap(Self.candidate)
        // Reconcile with what the system holds: after a relaunch the old activity is still there. Keep the first,
        // end any other (one activity at most).
        let running = Activity<RoleActivityAttributes>.activities.filter {
            [.active, .stale].contains($0.activityState) && !ending.contains($0.id)
        }
        for extra in running.dropFirst() { end(extra) }
        let current = running.first
        let shown = current.map {
            LiveActivityPlan.Shown(eligibleRoleId: $0.attributes.eligibleRoleId, endAt: $0.content.state.endAt,
                                   otherActive: $0.content.state.otherActive)
        }
        let canStart = UIApplication.shared.applicationState == .active && ActivityAuthorizationInfo().areActivitiesEnabled
        switch LiveActivityPlan.decide(candidates: candidates, shown: shown, enabled: isEnabled, canStart: canStart,
                                       now: .now, held: heldRoles()) {
        case .none:
            break
        case .start(let target):
            start(target)
        case .update(let target):
            guard let current else { return }
            let id = current.id, state = Self.state(target), endAt = target.role.endAt
            Task { await Self.update(id: id, state: state, staleDate: endAt) }
        case .replace(let target):
            if let current { end(current) }
            start(target)
        case .end:
            if let current { end(current) }
        }
    }

    private func start(_ target: LiveActivityPlan.Target) {
        let role = target.role
        let attributes = RoleActivityAttributes(roleName: role.roleName, scopeName: role.scopeName, source: role.source,
                                                eligibleRoleId: role.eligibleRoleId)
        // Refused when Live Activities are off for AzPim or the system limit is reached: nothing to show then.
        // `staleDate` = the end: past it the system shows the activity as outdated even if the app never runs again.
        let content = ActivityContent(state: Self.state(target), staleDate: role.endAt)
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    private func end(_ activity: Activity<RoleActivityAttributes>) {
        let id = activity.id
        ending.insert(id)
        Task {
            await Self.end(id: id)
            ending.remove(id)
        }
    }

    /// Roles with an Extend running, or sent within `extendGrace`.
    private func heldRoles() -> Set<String> {
        let since = Date.now.addingTimeInterval(-Self.extendGrace)
        let extend = ActivationAction.extend.rawValue
        let recent = FetchDescriptor<ActivationRecord>(predicate: #Predicate { $0.actionRaw == extend && $0.sentAt > since })
        let ids = ((try? store.context.fetch(recent)) ?? []).map(\.eligibleRoleId)
        return store.extending.union(ids)
    }

    private static func state(_ target: LiveActivityPlan.Target) -> RoleActivityAttributes.ContentState {
        .init(endAt: target.role.endAt, otherActive: target.otherActive)
    }

    // `Activity` is not Sendable: the async calls find it again by id off the main actor instead of sending it there.
    private nonisolated static func update(id: String, state: RoleActivityAttributes.ContentState, staleDate: Date) async {
        for activity in Activity<RoleActivityAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        }
    }

    private nonisolated static func end(id: String) async {
        for activity in Activity<RoleActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Activations without an end (none for an activated role, in practice) or without their eligible role (needed
    /// for Extend) are left out.
    private static func candidate(_ assignment: ActiveAssignment) -> LiveActivityPlan.Candidate? {
        guard let endAt = assignment.endAt, let role = assignment.eligibleRole else { return nil }
        return LiveActivityPlan.Candidate(eligibleRoleId: role.id, roleName: assignment.displayRoleName,
                                          scopeName: assignment.displayScopeName, source: assignment.source.rawValue,
                                          endAt: endAt)
    }
}
