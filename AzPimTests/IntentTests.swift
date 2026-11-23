@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Shortcuts actions through their seam (`RoleStore+Intents`), without the App Intents runtime: confirmation, missing
/// fields, the link setting, Deactivate all.
@MainActor
struct IntentTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1", role: "Owner"), Fixture.eligibility("e2", role: "Reader")])
    }

    private var roleId: String { "\(account.id.uuidString)|e1" }

    private func refresh(policy: RolePolicy) async {
        await arm.set(policy: .success(policy))
        await harness.refresh()
    }

    private func request(justification: String? = nil, ticket: String? = nil) -> RoleStore.IntentRequest {
        RoleStore.IntentRequest(roleId: roleId, minutes: nil, justification: justification, ticket: ticket)
    }

    /// The confirmation shows role, scope and duration; declining it sends nothing.
    @Test func activationIsConfirmedFirst() async throws {
        await refresh(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        var shown: [String] = []
        await #expect(throws: RoleStore.intentCancelled) {
            try await harness.store.intentActivate(request(), allowed: true, ask: { _ in nil },
                                                   confirm: { shown.append($0); return false })
        }
        #expect(shown.count == 1)
        let text = try #require(shown.first)
        #expect(text.contains("Owner") && text.contains("Scope e1"))
        #expect(text.contains(ISODuration.label(3600)))
        #expect(await arm.activateCount == 0)
        #expect(harness.records().isEmpty)
    }

    /// Missing fields are asked, then the confirmed request carries them.
    @Test func requiredFieldsAreAskedThenSent() async throws {
        await refresh(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: true, requiresTicket: true))
        var asked: [RoleStore.IntentField] = []
        var shown = ""
        let text = try await harness.store.intentActivate(
            request(), allowed: true,
            ask: { field in asked.append(field); return field == .justification ? "Audit" : "INC-1" },
            confirm: { shown = $0; return true })
        #expect(asked == [.justification, .ticket])
        #expect(shown.contains("Audit") && shown.contains("INC-1"))
        #expect(text.contains("is active until"))
        #expect(await arm.activateCount == 1)
        let record = try #require(harness.records().first)
        #expect(record.justification == "Audit")
        #expect(record.ticketNumber == "INC-1")
        #expect(record.panelOpenedAt == nil)
    }

    @Test func aMissingJustificationIsRefused() async throws {
        await refresh(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: true))
        var confirmed = 0
        await #expect(throws: RoleStore.IntentFailure(message: ActivationBlock.justificationRequired.message)) {
            try await harness.store.intentActivate(request(justification: "  "), allowed: true, ask: { _ in "" },
                                                   confirm: { _ in confirmed += 1; return true })
        }
        #expect(confirmed == 0)
        #expect(await arm.activateCount == 0)
        #expect(harness.records().isEmpty)
    }

    @Test func anUnreadablePolicyIsRefused() async throws {
        await arm.set(policy: .failure(URLError(.timedOut)))
        await harness.refresh()
        await #expect(throws: RoleStore.IntentFailure.self) {
            try await harness.store.intentActivate(request(justification: "Audit", ticket: "INC-1"), allowed: true,
                                                   ask: { _ in nil }, confirm: { _ in true })
        }
        #expect(await arm.activateCount == 0)
    }

    /// Settings › links may activate turned off: nothing is asked, confirmed or sent, for a role or a favorite.
    @Test func theLinkSettingOffRefuses() async throws {
        await refresh(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        var calls = 0
        await #expect(throws: RoleStore.intentActivationDisabled) {
            try await harness.store.intentActivate(request(), allowed: false, ask: { _ in calls += 1; return nil },
                                                   confirm: { _ in calls += 1; return true })
        }
        let favorite = Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: roleId, duration: "PT1H")])
        harness.context.insert(favorite)
        await #expect(throws: RoleStore.intentActivationDisabled) {
            try await harness.store.intentRunFavorite(id: favorite.id, allowed: false, confirm: { _ in calls += 1; return true })
        }
        #expect(calls == 0)
        #expect(await arm.activateCount == 0)
    }

    @Test func aConfirmedFavoriteRuns() async throws {
        await refresh(policy: RolePolicy(maxDuration: "PT8H", requiresJustification: false))
        let favorite = Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: roleId, duration: "PT2H")])
        harness.context.insert(favorite)
        var shown = ""
        let text = try await harness.store.intentRunFavorite(id: favorite.id, allowed: true,
                                                             confirm: { shown = $0; return true })
        #expect(shown.contains("Morning") && shown.contains("Owner"))
        #expect(text == FavoriteRun.summary([FavoriteRoleResult(roleName: "Owner", status: .provisioned)]))
        #expect(harness.records().map(\.requestedDuration) == ["PT2H"])
    }

    /// Deactivate all lists every activation before acting, then sums up.
    @Test func deactivateAllConfirmsAndSumsUp() async throws {
        let first = Fixture.eligibility("e1", role: "Owner"), second = Fixture.eligibility("e2", role: "Reader")
        await arm.set(assignments: [Fixture.activation(first, instance: "i1"), Fixture.activation(second, instance: "i2")])
        await harness.refresh()
        let active = harness.store.intentRoles().filter(\.active)
        #expect(Set(active.map(\.name)) == ["Owner", "Reader"])
        #expect(harness.store.intentActiveSummary(active).split(separator: "\n").count == 2)

        await #expect(throws: RoleStore.intentCancelled) {
            try await harness.store.intentDeactivateAll(confirm: { _ in false })
        }
        #expect(await arm.deactivateCount == 0)

        var shown = ""
        let text = try await harness.store.intentDeactivateAll(confirm: { shown = $0; return true })
        #expect(shown.contains("Owner") && shown.contains("Reader"))
        #expect(text == IntentSummary.deactivated([.init(name: "Owner"), .init(name: "Reader")]))
        #expect(await arm.deactivateCount == 2)
        #expect(harness.store.intentRoles().filter(\.active).isEmpty)
        #expect(try await harness.store.intentDeactivateAll(confirm: { _ in true }) == "No active role to deactivate.")
    }

    /// The search matches the displayed and the raw names.
    @Test func rolesAreSearchable() async throws {
        await harness.refresh()
        #expect(harness.store.intentRoles(matching: "read").map(\.name) == ["Reader"])
        #expect(harness.store.intentRoles().count == 2)
    }
}
