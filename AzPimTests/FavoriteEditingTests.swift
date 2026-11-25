@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Favorite edits shared by the Mac and the iPhone (`RoleStore+FavoriteEditing`): naming, duplicates, order, items,
/// durations, and the notification the iPhone's widget snapshot follows.
@MainActor
struct FavoriteEditingTests {
    let harness: Harness
    let account: Account

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        await sources[0].set(eligible: [Fixture.eligibility("e1"), Fixture.eligibility("e2", role: "Reader")])
        await harness.refresh()
    }

    private var store: RoleStore { harness.store }

    private func favorites() throws -> [Favorite] {
        try harness.context.fetch(FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    @Test func uniqueNamesSkipTakenOnesWhateverTheCase() {
        #expect(RoleStore.uniqueFavoriteName("Deploy", existing: []) == "Deploy")
        #expect(RoleStore.uniqueFavoriteName("Deploy", existing: ["deploy"]) == "Deploy 2")
        #expect(RoleStore.uniqueFavoriteName("Deploy", existing: ["Deploy", "DEPLOY 2"]) == "Deploy 3")
        // Bounded search: stops at the bound even if still taken.
        #expect(RoleStore.uniqueFavoriteName("A", existing: ["A", "A 2", "A 3"], maxIndex: 3) == "A 2")
    }

    @Test func newFavoriteIsNamedAfterTheRoleAndGoesLast() throws {
        let role = try #require(harness.role(account, "e1"))
        let first = store.newFavorite(with: role, among: try favorites())
        let second = store.newFavorite(with: role, among: try favorites())
        #expect(first.name == "Contributor")
        #expect(second.name == "Contributor 2")
        #expect(first.sortOrder == 0 && second.sortOrder == 1)
        #expect(second.items == [FavoriteItem(eligibleRoleId: role.id, duration: "PT1H")])
    }

    @Test func longRoleNamesLeaveRoomForTheSuffix() throws {
        let role = try #require(harness.role(account, "e1"))
        role.roleName = String(repeating: "x", count: 60)
        let first = store.newFavorite(with: role, among: try favorites())
        let second = store.newFavorite(with: role, among: try favorites())
        #expect(first.name.count == 34)
        #expect(second.name == first.name + " 2")
        #expect(second.name.count <= 40)
    }

    @Test func addingARoleTwiceIsANoOp() throws {
        let reader = try #require(harness.role(account, "e2"))
        let favorite = store.newFavorite(with: try #require(harness.role(account, "e1")), among: [])
        #expect(store.add(reader, to: favorite))
        #expect(!store.add(reader, to: favorite))
        #expect(favorite.items.map(\.eligibleRoleId) == [harness.role(account, "e1")?.id, reader.id].compactMap { $0 })
    }

    @Test func moveRenumbersTheOrder() throws {
        let role = try #require(harness.role(account, "e1"))
        for _ in 0..<3 { store.newFavorite(with: role, among: try favorites()) }
        store.moveFavorites(try favorites(), from: IndexSet(integer: 2), to: 0)
        #expect(try favorites().map(\.name) == ["Contributor 3", "Contributor", "Contributor 2"])
        #expect(try favorites().map(\.sortOrder) == [0, 1, 2])
    }

    @Test func removeItemAndDelete() throws {
        let contributor = try #require(harness.role(account, "e1"))
        let favorite = store.newFavorite(with: contributor, among: [])
        store.add(try #require(harness.role(account, "e2")), to: favorite)
        store.removeItem(contributor.id, from: favorite)
        #expect(favorite.items.map(\.eligibleRoleId) == [harness.role(account, "e2")?.id])
        store.delete(favorite)
        #expect(try favorites().isEmpty)
    }

    @Test func renameIsValidated() throws {
        let role = try #require(harness.role(account, "e1"))
        let favorite = store.newFavorite(with: role, among: [])
        #expect(store.rename(favorite, to: "  ", others: []) == .failure(.empty("name")))
        #expect(store.rename(favorite, to: "audit", others: ["Audit"]) == .failure(.duplicate("name")))
        #expect(favorite.name == "Contributor")
        #expect(store.rename(favorite, to: " Morning ", others: ["Audit"]) == .success("Morning"))
        #expect(favorite.name == "Morning")
    }

    @Test func durationIsStoredAndShownCappedByThePolicy() throws {
        let role = try #require(harness.role(account, "e1"))
        let favorite = store.newFavorite(with: role, among: [])
        store.setDuration(minutes: 150, roleId: role.id, in: favorite)
        #expect(favorite.items.first?.duration == "PT2H30M")
        #expect(RoleStore.favoriteDurationMinutes(favorite, roleId: role.id, policyMax: "PT8H") == 150)
        #expect(RoleStore.favoriteDurationMinutes(favorite, roleId: role.id, policyMax: "PT1H") == 60)
        store.setDuration(minutes: 30, roleId: "unknown", in: favorite)
        #expect(favorite.items.count == 1)
    }

    @Test func everyEditIsAnnounced() throws {
        let role = try #require(harness.role(account, "e1"))
        final class Counter: @unchecked Sendable { var value = 0 }
        let posted = Counter()
        let observer = NotificationCenter.default.addObserver(forName: RoleStore.favoritesDidChange, object: store,
                                                              queue: nil) { _ in posted.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let favorite = store.newFavorite(with: role, among: [])
        store.setDuration(minutes: 30, roleId: role.id, in: favorite)
        store.rename(favorite, to: "Renamed", others: [])
        store.rename(favorite, to: "Renamed", others: [])   // unchanged: nothing saved
        store.delete(favorite)
        #expect(posted.value == 4)
    }
}
