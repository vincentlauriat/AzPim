@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Quick activation (palette Return, panel Return, ⌥-click): one request with the default duration when the policy asks
/// for nothing else; otherwise no request at all, and the sheet opens.
@MainActor
struct QuickActivateTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1")])
    }

    /// Sets the policy Azure answers, then refreshes (the refresh reads it).
    private func role(policy: RolePolicy) async throws -> EligibleRole {
        await arm.set(policy: .success(policy))
        await harness.refresh()
        return try #require(harness.role(account, "e1"))
    }

    @Test func aRequiredJustificationSendsNothing() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: true))
        #expect(await harness.store.quickActivate(role) == .needsSheet)
        #expect(await arm.activateCount == 0)
        #expect(harness.records().isEmpty)
    }

    /// A justification remembered from an earlier request does not change it: the sheet shows it first.
    @Test func aRememberedJustificationStillOpensTheSheet() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: true))
        role.lastJustification = "Audit"
        #expect(await harness.store.quickActivate(role) == .needsSheet)
        #expect(await arm.activateCount == 0)
    }

    @Test func aRequiredTicketSendsNothing() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false, requiresTicket: true))
        #expect(await harness.store.quickActivate(role) == .needsSheet)
        #expect(await arm.activateCount == 0)
        #expect(harness.records().isEmpty)
    }

    /// A policy that cannot be read is not taken from its defaults.
    @Test func anUnreadablePolicySendsNothing() async throws {
        await arm.set(policy: .failure(URLError(.timedOut)))
        await harness.refresh()
        let role = try #require(harness.role(account, "e1"))
        #expect(role.policyFetchedAt == nil)
        #expect(await harness.store.quickActivate(role) == .needsSheet)
        #expect(await arm.activateCount == 0)
    }

    @Test func allowedSendsOneRequestWithTheDefaultDuration() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        #expect(await harness.store.quickActivate(role) == .sent(.provisioned))
        #expect(await arm.activateCount == 1)
        #expect(harness.records().map(\.requestedDuration) == ["PT1H"])
        #expect(harness.records().map(\.action) == [.activate])
    }

    /// An optional justification is sent empty (no old text reaches the audit log unseen), and the one remembered for
    /// the sheet, favorites and Extend is kept.
    @Test func allowedSendsAnEmptyJustificationAndKeepsTheLastOne() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        // A sheet activation remembers « Audit » (History keeps its record, so the purge keeps it too).
        await harness.store.activate(role, input: ActivationInput(duration: "PT1H", justification: "Audit"))
        await arm.set(assignments: [])   // that activation ended
        await harness.refresh()
        let again = try #require(harness.role(account, "e1"))
        #expect(again.lastJustification == "Audit")
        #expect(await harness.store.quickActivate(again) == .sent(.provisioned))
        #expect(harness.records().map { $0.justification ?? "" } == ["Audit", ""])
        #expect(try #require(harness.role(account, "e1")).lastJustification == "Audit")
    }

    @Test func allowedUsesTheRememberedDuration() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        harness.store.rememberDuration("PT45M", for: role)
        #expect(await harness.store.quickActivate(role) == .sent(.provisioned))
        #expect(harness.records().map(\.requestedDuration) == ["PT45M"])
    }

    @Test func allowedIsCappedByAShortPolicy() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT30M", requiresJustification: false))
        #expect(await harness.store.quickActivate(role) == .sent(.provisioned))
        #expect(harness.records().map(\.requestedDuration) == ["PT30M"])
    }

    /// A request already waiting is not sent a second time by a repeated Return.
    @Test func aWaitingRequestBlocks() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        await arm.set(activate: [.success(RequestOutcome(requestId: "r1", status: .pendingApproval))], for: "e1")
        #expect(await harness.store.quickActivate(role) == .sent(.pendingApproval))
        let again = await harness.store.quickActivate(role)
        #expect(again == .blocked(ActivationBlock.pending.message))
        #expect(await arm.activateCount == 1)
        #expect(harness.store.rowErrors[role.id] == ActivationBlock.pending.message)
    }

    @Test func offlineBlocks() async throws {
        let role = try await role(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        await arm.fail(with: URLError(.notConnectedToInternet))
        await harness.refresh()
        #expect(await harness.store.quickActivate(role) == .blocked(ActivationBlock.offline.message))
        #expect(await arm.activateCount == 0)
    }
}
