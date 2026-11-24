@testable import AzPim
import Foundation
import Testing

/// The iPhone Live Activity's decisions (`LiveActivityPlan`): which activation it shows, and when it starts, updates,
/// is replaced or ends. ActivityKit itself is iOS only; `LiveActivityController` applies these decisions.
struct LiveActivityPlanTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func candidate(_ id: String, in minutes: Double) -> LiveActivityPlan.Candidate {
        LiveActivityPlan.Candidate(eligibleRoleId: id, roleName: "Role \(id)", scopeName: "Scope", source: "azureResource",
                                   endAt: now.addingTimeInterval(minutes * 60))
    }

    func shown(_ candidate: LiveActivityPlan.Candidate, others: Int) -> LiveActivityPlan.Shown {
        LiveActivityPlan.Shown(eligibleRoleId: candidate.eligibleRoleId, endAt: candidate.endAt, otherActive: others)
    }

    @Test func targetIsTheActivationThatEndsFirstAmongLiveOnes() throws {
        let late = candidate("a", in: 120), soon = candidate("b", in: 30), expired = candidate("c", in: -1)
        let target = try #require(LiveActivityPlan.target([late, expired, soon], now: now))
        #expect(target.role == soon)
        #expect(target.otherActive == 1)   // the expired one does not count
        #expect(LiveActivityPlan.target([expired], now: now) == nil)
        #expect(LiveActivityPlan.target([], now: now) == nil)
    }

    @Test func sameEndPicksTheSameRoleWhateverTheOrder() throws {
        let first = candidate("a", in: 30), second = candidate("b", in: 30)
        let one = try #require(LiveActivityPlan.target([first, second], now: now))
        let other = try #require(LiveActivityPlan.target([second, first], now: now))
        #expect(one == other)
    }

    @Test func startsOnlyInTheForeground() {
        let role = candidate("a", in: 60)
        let target = LiveActivityPlan.Target(role: role, otherActive: 0)
        #expect(LiveActivityPlan.decide(candidates: [role], shown: nil, enabled: true, canStart: true, now: now) == .start(target))
        #expect(LiveActivityPlan.decide(candidates: [role], shown: nil, enabled: true, canStart: false, now: now) == .none)
    }

    @Test func nothingShownAndNothingToShowDoesNothing() {
        #expect(LiveActivityPlan.decide(candidates: [], shown: nil, enabled: true, canStart: true, now: now) == .none)
        #expect(LiveActivityPlan.decide(candidates: [candidate("a", in: 5)], shown: nil, enabled: false, canStart: true,
                                        now: now) == .none)
    }

    @Test func unchangedContentIsNotUpdated() {
        let role = candidate("a", in: 60)
        #expect(LiveActivityPlan.decide(candidates: [role], shown: shown(role, others: 0), enabled: true, canStart: false,
                                        now: now) == .none)
    }

    /// After an Extend (new end) or another activation (new count), even from the background.
    @Test func newEndOrCountUpdatesTheRunningActivity() {
        let role = candidate("a", in: 60), extended = candidate("a", in: 180), other = candidate("b", in: 240)
        #expect(LiveActivityPlan.decide(candidates: [extended], shown: shown(role, others: 0), enabled: true, canStart: false,
                                        now: now) == .update(.init(role: extended, otherActive: 0)))
        #expect(LiveActivityPlan.decide(candidates: [role, other], shown: shown(role, others: 0), enabled: true,
                                        canStart: false, now: now) == .update(.init(role: role, otherActive: 1)))
    }

    /// Another role ends first (Extend pushed the shown one later, or a shorter activation): a new activity, since
    /// the role is a static attribute. In the background it cannot start: the shown role stays while still live.
    @Test func anotherRoleEndingFirstReplacesTheActivityInTheForeground() {
        let extended = candidate("a", in: 180), soon = candidate("b", in: 30)
        let running = LiveActivityPlan.Shown(eligibleRoleId: "a", endAt: now.addingTimeInterval(600), otherActive: 1)
        #expect(LiveActivityPlan.decide(candidates: [extended, soon], shown: running, enabled: true, canStart: true,
                                        now: now) == .replace(.init(role: soon, otherActive: 1)))
        #expect(LiveActivityPlan.decide(candidates: [extended, soon], shown: running, enabled: true, canStart: false,
                                        now: now) == .none)
        #expect(LiveActivityPlan.decide(candidates: [soon], shown: running, enabled: true, canStart: false, now: now) == .end)
    }

    @Test func endsWhenNoActivationRemainsOrTheSettingIsOff() {
        let role = candidate("a", in: 60)
        #expect(LiveActivityPlan.decide(candidates: [], shown: shown(role, others: 0), enabled: true, canStart: false,
                                        now: now) == .end)
        #expect(LiveActivityPlan.decide(candidates: [candidate("a", in: -1)], shown: shown(role, others: 0), enabled: true,
                                        canStart: true, now: now) == .end)
        #expect(LiveActivityPlan.decide(candidates: [role], shown: shown(role, others: 0), enabled: false, canStart: true,
                                        now: now) == .end)
    }
}

/// The store calls `onRefreshed` at the end of every refresh: the iPhone's Live Activity follows activations, Extend,
/// deactivations and expiries through it.
@MainActor
struct RefreshHookTests {
    @Test func refreshCallsTheHookOnce() async throws {
        let harness = try Harness()
        var calls = 0
        harness.store.onRefreshed = { calls += 1 }
        await harness.refresh()
        #expect(calls == 1)
    }
}
