@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// The iPhone widgets' snapshot (2.0 step 4b): what the app writes (`RoleStore.widgetSnapshot`), its encoding, when
/// the widgets must be redrawn without the app, and the favorite links. WidgetKit itself is iOS only.
@MainActor
struct WidgetSnapshotTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func role(_ id: String, endingIn minutes: Double?) -> WidgetSnapshot.Role {
        WidgetSnapshot.Role(id: id, name: "Role \(id)", scope: "Scope", symbol: "cloud",
                            startAt: minutes.map { _ in now.addingTimeInterval(-3600) },
                            endAt: minutes.map { now.addingTimeInterval($0 * 60) })
    }

    // MARK: Building

    /// The panel's rows: activations ending first on top, then permanent assignments; expired ones left out; the
    /// favorites in the app's order with their role count. Display names only, no account.
    @Test func snapshotListsWhatThePanelShows() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let late = Fixture.eligibility("e1"), soon = Fixture.eligibility("e2", role: "Reader")
        let gone = Fixture.eligibility("e3", role: "Owner")
        let permanent = RemoteAssignment(id: "p1", source: .azureResource, roleDefinitionId: "rd-perm",
                                         roleName: "Billing Reader", scope: "/scope/perm", scopeName: "Scope perm",
                                         type: .assigned, startAt: .now.addingTimeInterval(-86_400), endAt: nil,
                                         linkedEligibilityId: nil)
        await sources[0].set(eligible: [late, soon, gone], assignments: [
            Fixture.activation(late, instance: "i1", end: .now.addingTimeInterval(7200)),
            Fixture.activation(soon, instance: "i2", end: .now.addingTimeInterval(600)),
            Fixture.activation(gone, instance: "i3", end: .now.addingTimeInterval(-60)),
            permanent
        ])
        await harness.refresh()
        let roleId = "\(account.id.uuidString)|e1"
        harness.context.insert(Favorite(name: "Second", items: [], sortOrder: 1))
        harness.context.insert(Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: roleId, duration: "PT1H"),
                                                                 FavoriteItem(eligibleRoleId: roleId, duration: "PT2H")]))

        let snapshot = harness.store.widgetSnapshot()
        #expect(snapshot.roles.map(\.name) == ["Reader", "Contributor", "Billing Reader"])
        #expect(snapshot.roles.map(\.scope) == ["Scope e2", "Scope e1", "Scope perm"])
        #expect(snapshot.roles.map(\.symbol) == ["cloud", "cloud", "cloud"])
        let last = try #require(snapshot.roles.last)
        #expect(last.isPermanent && last.startAt == nil)
        #expect(snapshot.roles.first?.startAt != nil)
        #expect(snapshot.favorites.map(\.name) == ["Morning", "Second"])
        #expect(snapshot.favorites.map(\.roleCount) == [2, 0])
        // Nothing about the account: no UPN, tenant or object id in the file.
        let text = try #require(String(bytes: try snapshot.encoded(), encoding: .utf8))
        #expect(!text.contains("user@test") && !text.contains("tenant-1") && !text.contains("oid-1"))
        #expect(!text.contains(account.id.uuidString))
    }

    /// One account per identity: the Azure CLI account a Microsoft sign-in supersedes adds no second row.
    @Test func supersededAccountsAddNoRow() async throws {
        let harness = try Harness()
        let (_, msalSources) = harness.addAccount(.msal, sortOrder: 0)
        let (_, cliSources) = harness.addAccount(.azureCLI, sortOrder: 1)
        let role = Fixture.eligibility("e1")
        await cliSources[0].set(eligible: [role], assignments: [Fixture.activation(role, instance: "i1")])
        await msalSources[0].set(eligible: [role], assignments: [Fixture.activation(role, instance: "i1")])
        await harness.refresh()
        #expect(harness.store.widgetSnapshot().roles.count == 1)
    }

    // MARK: Encoding

    @Test func encodingRoundTripsExactly() throws {
        let snapshot = WidgetSnapshot(generatedAt: now.addingTimeInterval(0.123),
                                      roles: [role("a", endingIn: 30.5), role("b", endingIn: nil)],
                                      favorites: [.init(id: UUID(), name: "Morning « é »", roleCount: 3)])
        let data = try snapshot.encoded()
        #expect(WidgetSnapshot.decode(data) == snapshot)
        #expect(try snapshot.encoded() == data)   // stable bytes (sorted keys)
        #expect(WidgetSnapshot.decode(Data("not json".utf8)) == nil)
    }

    @Test func readsTheFileTheAppWrote() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WidgetSnapshot.read(from: url) == nil)
        #expect(WidgetSnapshot.read(from: nil) == nil)
        let snapshot = WidgetSnapshot(generatedAt: now, roles: [role("a", endingIn: 10)], favorites: [])
        try snapshot.encoded().write(to: url, options: .atomic)
        #expect(WidgetSnapshot.read(from: url) == snapshot)
    }

    /// The widgets reload only when the roles or favorites change, not on every refresh.
    @Test func sameContentIgnoresTheGenerationDate() {
        let first = WidgetSnapshot(generatedAt: now, roles: [role("a", endingIn: 10)], favorites: [])
        let later = WidgetSnapshot(generatedAt: now.addingTimeInterval(60), roles: first.roles, favorites: [])
        #expect(first.hasSameContent(as: later))
        #expect(!first.hasSameContent(as: nil))
        #expect(!first.hasSameContent(as: WidgetSnapshot(generatedAt: now, roles: [role("a", endingIn: 20)], favorites: [])))
    }

    // MARK: Timeline

    /// Now, then each colour threshold (15 and 5 minutes left) and each end, in order; past dates left out.
    @Test func entriesAtEachThresholdAndEnd() {
        let snapshot = WidgetSnapshot(generatedAt: now, roles: [role("a", endingIn: 60), role("b", endingIn: 10),
                                                                 role("p", endingIn: nil), role("x", endingIn: -5)],
                                      favorites: [])
        let minutes = snapshot.entryDates(now: now).map { $0.timeIntervalSince(now) / 60 }
        #expect(minutes == [0, 5, 10, 45, 55, 60])
        #expect(snapshot.reloadDate(after: snapshot.entryDates(now: now)) == nil)
    }

    /// Each entry shows the roles still live at its date: an expired role disappears without the app.
    @Test func expiredRolesLeaveTheEntry() {
        let snapshot = WidgetSnapshot(generatedAt: now, roles: [role("a", endingIn: 10), role("p", endingIn: nil)],
                                      favorites: [])
        #expect(snapshot.liveRoles(at: now).map(\.id) == ["a", "p"])
        #expect(snapshot.liveRoles(at: now.addingTimeInterval(600)).map(\.id) == ["p"])
    }

    @Test func noActivationMeansOneEntryAndNoReload() {
        let snapshot = WidgetSnapshot(generatedAt: now, roles: [role("p", endingIn: nil)], favorites: [])
        #expect(snapshot.entryDates(now: now) == [now])
        #expect(snapshot.reloadDate(after: [now]) == nil)
    }

    /// Beyond the entry budget the timeline asks again at its last entry.
    @Test func manyActivationsReloadAfterTheLastEntry() throws {
        let roles = (1...30).map { role("r\($0)", endingIn: Double($0) * 30) }
        let snapshot = WidgetSnapshot(generatedAt: now, roles: roles, favorites: [])
        let dates = snapshot.entryDates(now: now)
        #expect(dates.count == WidgetSnapshot.maxEntries)
        #expect(dates == dates.sorted())
        #expect(snapshot.reloadDate(after: dates) == dates.last)
    }

    // MARK: Links

    @Test func favoriteLinksRoundTrip() throws {
        let id = UUID()
        let url = try #require(WidgetSnapshot.favoriteURL(id))
        #expect(url.absoluteString == "azpim://favorite?id=\(id.uuidString)")
        #expect(WidgetSnapshot.favoriteID(in: url) == id)
        #expect(WidgetSnapshot.favoriteID(in: try #require(URL(string: "azpim://favorite?id=nope"))) == nil)
        #expect(WidgetSnapshot.favoriteID(in: try #require(URL(string: "azpim://role?id=\(id.uuidString)"))) == nil)
        #expect(WidgetSnapshot.favoriteID(in: try #require(URL(string: "https://favorite?id=\(id.uuidString)"))) == nil)
    }
}
