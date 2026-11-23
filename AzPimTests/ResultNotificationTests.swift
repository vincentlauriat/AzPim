@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// 1.0 item 9: action results are notified (counts only, never a modal for a success) and shown inline; failures from
/// links stay dialogs; onboarding summary counts.
@MainActor
struct ResultNotificationTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        let reader = Fixture.eligibility("e1", role: "Reader"), owner = Fixture.eligibility("e2", role: "Owner")
        await arm.set(eligible: [reader, owner, Fixture.eligibility("e3", role: "Contributor")],
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

    /// A full success (link, grouped sheet): the counts are notified; the favorite's toast is the inline status.
    @Test func favoriteSuccessIsNotifiedWithCountsOnly() async throws {
        let favorite = favorite()
        let outcome = await harness.store.runFavorite(favorite, fromPanel: false)
        #expect(outcome.isFullSuccess)
        #expect(await harness.store.announce(favorite: favorite.name, outcome))
        let posted = try #require(harness.center.immediate.first)
        #expect(posted.title == "Morning")
        #expect(posted.body == "Activated: 1 of 1.")
        #expect(posted.id.hasPrefix(NotificationScheduler.resultPrefix))
        #expect(posted.category == nil)
        #expect(harness.store.favoriteToast?.text == outcome.text)
        #expect(harness.store.lastResult == nil)   // no second line under the toast
    }

    /// A failed role is not a full success (a link shows a dialog); the notification body holds counts, never
    /// Azure's error text.
    @Test func failedRoleIsNotAFullSuccess() async throws {
        await arm.set(activate: [.failure(PIMError.http(status: 403, code: nil, message: "Secret detail"))], for: "e1")
        let outcome = await harness.store.runFavorite(favorite(), fromPanel: false)
        #expect(!outcome.isFullSuccess)
        #expect(outcome.text.contains("Reader"))
        #expect(outcome.notificationBody == "Activated: 0 of 1, failed: 1 — open AzPim.")
        #expect(!outcome.notificationBody.contains("Secret"))
    }

    /// Already running: nothing sent, and never reported as a success.
    @Test func alreadyRunningIsReported() async throws {
        let favorite = favorite()
        harness.store.runningFavorites.insert(favorite.id)
        let outcome = await harness.store.runFavorite(favorite, fromPanel: false)
        #expect(outcome.alreadyRunning)
        #expect(!outcome.isFullSuccess)
        #expect(outcome.text == "Morning is already running.")
        #expect(await arm.activateCount == 0)
    }

    /// Notifications denied: nothing is posted, the inline status stays (never a modal).
    @Test func deniedPermissionFallsBackToInlineStatus() async throws {
        harness.center.authorized = false
        let role = try #require(harness.role(account, "e1"))
        await harness.store.announceActivation(of: role, status: .pendingApproval,
                                               input: ActivationInput(duration: "PT1H", justification: ""))
        #expect(harness.store.lastResult?.body == "Request sent — pending approval.")
        #expect(harness.store.lastResult?.isRecent(at: .now) == true)
        let favorite = favorite()
        let outcome = await harness.store.runFavorite(favorite)
        #expect(await harness.store.announce(favorite: favorite.name, outcome) == false)
        #expect(harness.center.immediate.isEmpty)
        #expect(harness.store.favoriteToast?.text == outcome.text)
    }

    /// A one-click run from the panel keeps its toast only: no notification while the user looks at the result.
    @Test func panelRunIsNotNotified() async throws {
        await harness.store.run(favorite())
        #expect(harness.center.immediate.isEmpty)
        #expect(harness.store.lastResult == nil)
    }

    /// Activation Sheet: an accepted activation is notified with the role to open, without Extend (the expiry
    /// reminder has it).
    @Test func activationResultIsNotified() async throws {
        let role = try #require(harness.role(account, "e1"))
        let input = ActivationInput(duration: "PT1H", justification: "Audit")
        let status = try #require(await harness.store.activate(role, input: input))
        await harness.store.announceActivation(of: role, status: status, input: input)
        let posted = try #require(harness.center.immediate.first)
        #expect(posted.title == "\(role.displayRoleName) — \(role.displayScopeName)")
        #expect(posted.body.hasPrefix("Active until"))
        #expect(posted.roleId == role.id)
        #expect(posted.category == nil)
        #expect(harness.store.lastResult?.roleId == role.id)
    }

    @Test func onboardingSummaryCountsTheAccountAdded() async throws {
        let counts = harness.store.summary(of: account)
        #expect(counts.eligible == 3)
        #expect(counts.active == 1)
        #expect(RoleStore.summaryText(eligible: 3, active: 1) == "Account added: 3 eligible roles, 1 active")
        #expect(RoleStore.summaryText(eligible: 1, active: 0) == "Account added: 1 eligible role, 0 active")
    }
}
