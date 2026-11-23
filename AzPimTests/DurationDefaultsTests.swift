@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Least-privilege defaults in the store: the last duration used per role, else 1 h, capped by the policy.
@MainActor
struct DurationDefaultsTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource
    let eligibility = Fixture.eligibility("e1")

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [eligibility])
        await harness.refresh()
    }

    private var role: EligibleRole? { harness.role(account, "e1") }

    @Test func oneHourWithoutAMemory() throws {
        let role = try #require(role)
        #expect(role.maxDuration == "PT8H")
        #expect(harness.store.defaultDurationMinutes(for: role) == 60)
        #expect(harness.store.defaultFavoriteDuration(for: role) == "PT1H")
    }

    @Test func anAcceptedActivationIsRemembered() async throws {
        let role = try #require(role)
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT2H15M", justification: "Deploy"),
                                                  remembersDuration: true)
        #expect(status == .provisioned)
        #expect(harness.store.defaultDurationMinutes(for: try #require(self.role)) == 135)
        #expect(harness.store.defaultFavoriteDuration(for: try #require(self.role)) == "PT2H15M")
    }

    @Test func aFailedActivationIsNotRemembered() async throws {
        let role = try #require(role)
        await arm.set(activate: [.failure(PIMError.http(status: 403, code: nil, message: "No"))], for: "e1")
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT4H", justification: "Deploy"),
                                                  remembersDuration: true)
        #expect(status == nil)
        #expect(harness.store.defaultDurationMinutes(for: role) == 60)
    }

    @Test func theMemoryIsCappedByAShorterPolicy() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT6H", justification: "Deploy"), remembersDuration: true)
        let refreshed = try #require(self.role)
        refreshed.policy = RolePolicy(maxDuration: "PT2H")
        #expect(harness.store.defaultDurationMinutes(for: refreshed) == 120)
    }

    /// The Microsoft sign-in that supersedes the Azure CLI account reads the same role under another row id: the
    /// remembered duration follows it.
    @Test func theMemorySurvivesTheSupersede() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT45M", justification: "Audit"),
                                     refreshAfter: false, remembersDuration: true)
        let (msal, msalSources) = harness.addAccount(.msal, sortOrder: 1)
        await msalSources[0].set(eligible: [eligibility])
        await harness.refresh()
        let replacement = try #require(harness.role(msal, "e1"))
        #expect(replacement.id != role.id)
        #expect(harness.store.supersession().hides(account.id, .azureResource))
        #expect(harness.store.defaultDurationMinutes(for: replacement) == 45)
    }

    /// Only the sheet's choice is remembered: a favorite keeps its own duration and does not change the memory.
    @Test func aFavoriteRunIsNotRemembered() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT45M", justification: "Audit"), remembersDuration: true)
        let favorite = Favorite(name: "Deploy", items: [FavoriteItem(eligibleRoleId: role.id, duration: "PT4H",
                                                                     justification: "Deploy")])
        harness.context.insert(favorite)
        await arm.set(assignments: [])   // the sheet's activation ended: the favorite sends a request
        await harness.refresh()
        let text = await harness.store.run(favorite, fromPanel: false)
        #expect(text.hasPrefix("1 of 1 activated"))
        #expect(harness.records().compactMap(\.requestedDuration) == ["PT45M", "PT4H"])
        #expect(harness.store.defaultDurationMinutes(for: try #require(self.role)) == 45)
    }

    /// Extend after the Microsoft sign-in superseded the Azure CLI account: the records stay under the CLI account,
    /// so the remembered duration is used, not the policy maximum.
    @Test func extendAfterTheSupersedeUsesTheRememberedDuration() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT45M", justification: "Audit"),
                                     refreshAfter: false, remembersDuration: true)
        let (msal, msalSources) = harness.addAccount(.msal, sortOrder: 1)
        await msalSources[0].set(eligible: [eligibility], assignments: [Fixture.activation(eligibility, instance: "i1")])
        await harness.refresh()
        let replacement = try #require(harness.role(msal, "e1"))
        replacement.lastJustification = "Audit"
        let text = await harness.store.extend(eligibleRoleId: replacement.id)
        #expect(text.hasPrefix("Extended until"))
        #expect(harness.records().filter { $0.action == .extend }.map(\.requestedDuration) == ["PT45M"])
    }

    /// No duration anywhere: Extend asks for 1 h, never the policy maximum.
    /// (Activated elsewhere: no request of AzPim, so no justification, under a policy that asks for none.)
    @Test func extendWithoutAnyDurationUsesOneHour() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await arm.set(assignments: [Fixture.activation(eligibility, instance: "i1")])
        await harness.refresh()
        let text = await harness.store.extend(eligibleRoleId: try #require(role).id)
        #expect(text.hasPrefix("Extended until"))
        #expect(harness.records().filter { $0.action == .extend }.map(\.requestedDuration) == ["PT1H"])
    }

    /// Roles no longer cached lose their remembered duration; the others keep it.
    @Test func pruneKeepsOnlyCachedRoles() async throws {
        let other = Fixture.eligibility("e2")
        await arm.set(eligible: [eligibility, other])
        await harness.refresh()
        await harness.store.activate(try #require(role), input: ActivationInput(duration: "PT2H", justification: "D"),
                                     refreshAfter: false, remembersDuration: true)
        await harness.store.activate(try #require(harness.role(account, "e2")),
                                     input: ActivationInput(duration: "PT3H", justification: "D"), refreshAfter: false,
                                     remembersDuration: true)
        await arm.set(eligible: [other], assignments: [])
        await harness.refresh()   // e1 is gone; the purge after the refresh prunes it
        #expect(harness.store.durationMemory.load().count == 1)
        #expect(harness.store.defaultDurationMinutes(for: try #require(harness.role(account, "e2"))) == 180)
    }

    @Test func anotherRoleKeepsTheDefault() async throws {
        let other = Fixture.eligibility("e2")
        await arm.set(eligible: [eligibility, other])
        await harness.refresh()
        await harness.store.activate(try #require(role), input: ActivationInput(duration: "PT3H", justification: "Deploy"),
                                     remembersDuration: true)
        #expect(harness.store.defaultDurationMinutes(for: try #require(harness.role(account, "e2"))) == 60)
    }

    /// A request waiting for approval disables Activate with its reason, and the sheet would not send it twice.
    @Test func aWaitingRequestBlocksActivate() async throws {
        let role = try #require(role)
        await arm.set(activate: [.success(RequestOutcome(requestId: "r1", status: .pendingApproval))], for: "e1")
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT1H", justification: "Deploy"),
                                                  refreshAfter: false)
        #expect(status == .pendingApproval)
        let facts = ActivationBlock.Facts(inProgress: harness.store.busy.contains(role.id),
                                          pending: harness.store.waitingRequest(for: role) != nil,
                                          offline: harness.store.isOffline, minutes: 60, policyMax: role.maxDuration,
                                          requiresJustification: true, justification: "Deploy")
        #expect(ActivationBlock.reason(facts) == .pending)
    }

    @Test func offlineBlocksActivate() async throws {
        let role = try #require(role)
        await arm.fail(with: URLError(.notConnectedToInternet))
        await harness.refresh()
        #expect(harness.store.isOffline)
        let facts = ActivationBlock.Facts(offline: harness.store.isOffline, minutes: 60, policyMax: role.maxDuration,
                                          requiresJustification: true, justification: "Deploy")
        #expect(ActivationBlock.reason(facts) == .offline)
    }
}
