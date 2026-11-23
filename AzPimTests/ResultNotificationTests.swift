@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// 1.0 item 9: action results are notified (never a modal) and always shown inline; onboarding summary counts.
@MainActor
struct ResultNotificationTests {
    let harness: Harness
    let account: Account

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        let reader = Fixture.eligibility("e1", role: "Reader"), owner = Fixture.eligibility("e2", role: "Owner")
        await sources[0].set(eligible: [reader, owner, Fixture.eligibility("e3", role: "Contributor")],
                             assignments: [Fixture.activation(owner, instance: "i2")])
        await harness.refresh()
    }

    private func favorite() -> Favorite {
        let favorite = Favorite(name: "Morning", items: [
            FavoriteItem(eligibleRoleId: "\(account.id.uuidString)|e1", justification: "Daily ops")
        ])
        harness.context.insert(favorite)
        return favorite
    }

    /// A link or the grouped sheet: the run's result becomes a notification, plus the inline status.
    @Test func favoriteRunResultIsNotified() async throws {
        let text = await harness.store.run(favorite(), fromPanel: false, announce: true)
        let posted = harness.center.immediate
        #expect(posted.count == 1)
        #expect(posted.first?.title == "Morning")
        #expect(posted.first?.body == text)
        #expect(posted.first?.id.hasPrefix(NotificationScheduler.resultPrefix) == true)
        #expect(harness.store.lastResult?.body == text)
    }

    /// Notifications denied: nothing is posted (and no modal exists to fall back on), the inline status stays.
    @Test func deniedPermissionFallsBackToInlineStatus() async throws {
        harness.center.authorized = false
        let text = await harness.store.run(favorite(), fromPanel: false, announce: true)
        #expect(harness.center.immediate.isEmpty)
        #expect(harness.store.lastResult?.title == "Morning")
        #expect(harness.store.lastResult?.body == text)
        #expect(harness.store.lastResult?.isRecent(at: .now) == true)
        #expect(harness.store.favoriteToast?.text == text)
    }

    /// A one-click run from the panel keeps its toast only: no notification while the user looks at the result.
    @Test func panelRunIsNotNotified() async throws {
        await harness.store.run(favorite())
        #expect(harness.center.immediate.isEmpty)
        #expect(harness.store.lastResult == nil)
    }

    /// Activation Sheet: an activation Azure accepted is notified with Extend (now active) and the role to open.
    @Test func activationResultIsNotified() async throws {
        let role = try #require(harness.role(account, "e1"))
        let input = ActivationInput(duration: "PT1H", justification: "Audit")
        let status = try #require(await harness.store.activate(role, input: input))
        await harness.store.announceActivation(of: role, status: status, input: input)
        let posted = try #require(harness.center.immediate.first)
        #expect(posted.title == "\(role.displayRoleName) — \(role.displayScopeName)")
        #expect(posted.body.hasPrefix("Active until"))
        #expect(posted.roleId == role.id)
        #expect(posted.category == NotificationScheduler.category)
        #expect(harness.store.lastResult?.roleId == role.id)
    }

    @Test func pendingApprovalIsNotifiedWithoutExtend() async throws {
        let role = try #require(harness.role(account, "e1"))
        await harness.store.announceActivation(of: role, status: .pendingApproval,
                                               input: ActivationInput(duration: "PT1H", justification: ""))
        let posted = try #require(harness.center.immediate.first)
        #expect(posted.body == "Request sent — pending approval.")
        #expect(posted.category == nil)
    }

    @Test func onboardingSummaryCountsTheAccountAdded() async throws {
        let counts = harness.store.summary(of: account)
        #expect(counts.eligible == 3)
        #expect(counts.active == 1)
        #expect(RoleStore.summaryText(eligible: 3, active: 1) == "Account added: 3 eligible roles, 1 active")
        #expect(RoleStore.summaryText(eligible: 1, active: 0) == "Account added: 1 eligible role, 0 active")
    }
}
