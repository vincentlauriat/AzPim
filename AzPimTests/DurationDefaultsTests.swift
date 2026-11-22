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
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT2H15M", justification: "Deploy"))
        #expect(status == .provisioned)
        #expect(harness.store.defaultDurationMinutes(for: try #require(self.role)) == 135)
        #expect(harness.store.defaultFavoriteDuration(for: try #require(self.role)) == "PT2H15M")
    }

    @Test func aFailedActivationIsNotRemembered() async throws {
        let role = try #require(role)
        await arm.set(activate: [.failure(PIMError.http(status: 403, code: nil, message: "No"))], for: "e1")
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT4H", justification: "Deploy"))
        #expect(status == nil)
        #expect(harness.store.defaultDurationMinutes(for: role) == 60)
    }

    @Test func theMemoryIsCappedByAShorterPolicy() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT6H", justification: "Deploy"))
        let refreshed = try #require(self.role)
        refreshed.policy = RolePolicy(maxDuration: "PT2H")
        #expect(harness.store.defaultDurationMinutes(for: refreshed) == 120)
    }

    /// The Microsoft sign-in that supersedes the Azure CLI account reads the same role under another row id: the
    /// remembered duration follows it.
    @Test func theMemorySurvivesTheSupersede() async throws {
        let role = try #require(role)
        await harness.store.activate(role, input: ActivationInput(duration: "PT45M", justification: "Audit"),
                                     refreshAfter: false)
        let (msal, msalSources) = harness.addAccount(.msal, sortOrder: 1)
        await msalSources[0].set(eligible: [eligibility])
        await harness.refresh()
        let replacement = try #require(harness.role(msal, "e1"))
        #expect(replacement.id != role.id)
        #expect(harness.store.supersession().hides(account.id, .azureResource))
        #expect(harness.store.defaultDurationMinutes(for: replacement) == 45)
    }

    @Test func anotherRoleKeepsTheDefault() async throws {
        let other = Fixture.eligibility("e2")
        await arm.set(eligible: [eligibility, other])
        await harness.refresh()
        await harness.store.activate(try #require(role), input: ActivationInput(duration: "PT3H", justification: "Deploy"))
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
