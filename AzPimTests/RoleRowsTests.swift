@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// The rows of the Mac Roles Window and of the iPhone split view: built from the cache, then filtered.
@MainActor
struct RoleRowsTests {
    let harness: Harness
    let first: Account
    let second: Account

    init() async throws {
        harness = try Harness()
        let contributor = Fixture.eligibility("e1")
        let reader = Fixture.eligibility("e2", role: "Reader")
        // Reader is eligible and also assigned permanently (no activation): its eligible row says "Active · permanent"
        // and the permanent assignment keeps its own row, as in the Mac 1.0 Roles Window. Owner is only permanent.
        let readerPermanent = RemoteAssignment(id: "p2", source: .azureResource, roleDefinitionId: reader.roleDefinitionId,
                                               roleName: "Reader", scope: reader.scope, scopeName: reader.scopeName,
                                               type: .assigned, startAt: .now.addingTimeInterval(-86_400), endAt: nil, linkedEligibilityId: nil)
        let ownerPermanent = RemoteAssignment(id: "p3", source: .azureResource, roleDefinitionId: "rd-perm",
                                              roleName: "Owner", scope: "/scope/perm", scopeName: "Scope perm",
                                              type: .assigned, startAt: .now.addingTimeInterval(-86_400), endAt: nil, linkedEligibilityId: nil)
        let (first, arm) = harness.addAccount()
        await arm[0].set(eligible: [contributor, reader],
                         assignments: [Fixture.activation(contributor, instance: "i1"), readerPermanent, ownerPermanent])
        let (second, entra) = harness.addAccount(.msal, objectId: "oid-2", tenantId: "tenant-2", sortOrder: 1,
                                                 sources: [.entraRole])
        await entra[0].set(eligible: [Fixture.eligibility("g1", source: .entraRole, role: "Global Reader")], assignments: [])
        self.first = first
        self.second = second
        await harness.refresh()
    }

    func rows() throws -> [RoleRow] {
        let roles = try harness.context.fetch(FetchDescriptor<EligibleRole>())
        let assignments = try harness.context.fetch(FetchDescriptor<ActiveAssignment>())
        return RoleRows.make(roles: roles, assignments: assignments, supersession: harness.store.supersession(),
                             now: .now)
    }

    func names(_ rows: [RoleRow]) -> [String] { rows.map(\.roleName).sorted() }

    @Test func eligibleRowsPlusOneRowPerPermanentAssignment() throws {
        let all = try rows()
        #expect(names(all) == ["Contributor", "Global Reader", "Owner", "Reader", "Reader"])
        let reader = try #require(all.first { $0.roleName == "Reader" && !$0.isPermanent })
        #expect(reader.heldPermanently && !reader.isPermanent && reader.assignment == nil)
        let owner = try #require(all.first { $0.roleName == "Owner" })
        #expect(owner.isPermanent)
    }

    /// The selection is a row id: an activated role keeps the eligible role's id, not the activation's.
    @Test func activeRowKeepsTheEligibleRoleId() throws {
        let contributor = try #require(try rows().first { $0.roleName == "Contributor" })
        #expect(contributor.id == "\(first.id.uuidString)|e1")
        #expect(contributor.assignment != nil)
    }

    @Test func stateFilter() throws {
        let all = try rows()
        func by(_ state: RoleStateFilter) -> [String] {
            names(RoleRows.filter(all, source: nil, accountId: nil, state: state, search: ""))
        }
        #expect(by(.all).count == 5)
        #expect(by(.active) == ["Contributor", "Reader"])
        #expect(by(.eligible) == ["Global Reader"])
        #expect(by(.permanent) == ["Owner", "Reader"])
    }

    @Test func sourceAccountAndSearchFilters() throws {
        let all = try rows()
        #expect(names(RoleRows.filter(all, source: .entraRole, accountId: nil, state: .all, search: "")) == ["Global Reader"])
        #expect(names(RoleRows.filter(all, source: nil, accountId: second.id, state: .all, search: "")) == ["Global Reader"])
        #expect(names(RoleRows.filter(all, source: nil, accountId: nil, state: .all, search: "READER"))
            == ["Global Reader", "Reader", "Reader"])
        #expect(names(RoleRows.filter(all, source: nil, accountId: nil, state: .all, search: "scope e1")) == ["Contributor"])
        #expect(RoleRows.filter(all, source: .pimGroup, accountId: nil, state: .all, search: "").isEmpty)
    }
}
