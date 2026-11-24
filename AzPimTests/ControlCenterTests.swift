@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing
import UserNotifications

/// 2.0 step 4c: the iPhone's Control Center control « Run Favorite » never activates by itself, and the expiry
/// notification's Extend opens the app on iPhone only.
@MainActor
struct ControlCenterTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1", role: "Reader"), Fixture.eligibility("e2", role: "Owner")])
        await harness.refresh()
    }

    private func roleId(_ eligibility: String) -> String { "\(account.id.uuidString)|\(eligibility)" }

    /// A favorite that needs nothing (its justification is saved) still yields the sheet's request, and sends nothing.
    @Test func favoriteRequestNeverRuns() async throws {
        let favorite = Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: roleId("e1"), justification: "Daily ops")])
        harness.context.insert(favorite)
        let request = await harness.store.favoriteRunRequest(favorite)
        #expect(request.favorite.id == favorite.id)
        #expect(request.roles.map(\.role.id) == [roleId("e1")])
        #expect(!harness.store.favoriteNeeds(request.roles).any)
        #expect(await arm.activateCount == 0)
    }

    /// The control lists favorites in the panel's order, without the empty ones.
    @Test func runnableFavoritesSkipEmptyOnesInPanelOrder() {
        let second = Favorite(name: "Second", items: [FavoriteItem(eligibleRoleId: roleId("e2"))], sortOrder: 2)
        let empty = Favorite(name: "Empty", items: [], sortOrder: 0)
        let first = Favorite(name: "First", items: [FavoriteItem(eligibleRoleId: roleId("e1"))], sortOrder: 1)
        for favorite in [second, empty, first] { harness.context.insert(favorite) }
        #expect(harness.store.runnableFavorites().map(\.name) == ["First", "Second"])
    }

    /// Extend always needs an unlocked device; it opens the app only when asked (iPhone).
    @Test func extendOptions() {
        #expect(NotificationScheduler.extendOptions(opensApp: false) == [.authenticationRequired])
        #expect(NotificationScheduler.extendOptions(opensApp: true) == [.authenticationRequired, .foreground])
    }

    /// On the Mac, the registered Extend action runs where it is: it does not bring AzPim forward.
    @Test func macExtendStaysInTheBackground() throws {
        #expect(!NotificationScheduler.extendOpensApp)
        let category = try #require(harness.center.categories.first { $0.identifier == NotificationScheduler.category })
        let extend = try #require(category.actions.first { $0.identifier == NotificationScheduler.extendAction })
        #expect(extend.options == [.authenticationRequired])
    }
}
