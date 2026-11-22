import Foundation
import Testing
@testable import AzPimCore

/// One account per identity (supersede) and one row per role (merge).
struct RoleDedupTests {
    private let cliId = UUID()
    private let msalId = UUID()

    private func account(_ id: UUID, _ mode: SignInMode, tenant: String = "tenant-1", upn: String = "v.admin@contoso.com")
        -> AccountFacts {
        AccountFacts(id: id, mode: mode, tenantId: tenant, upn: upn)
    }

    // MARK: Supersede

    @Test func msalSupersedesCLIOfSameIdentityIgnoringCase() {
        let map = AccountSupersede.superseded([
            account(cliId, .azureCLI, tenant: "TENANT-1", upn: "V.Admin@Contoso.com"),
            account(msalId, .msal)
        ])
        #expect(map == [cliId: msalId])
    }

    @Test func otherTenantOrUPNIsNotSuperseded() {
        let otherTenant = UUID(), otherUser = UUID()
        let map = AccountSupersede.superseded([
            account(otherTenant, .azureCLI, tenant: "tenant-2"),
            account(otherUser, .azureCLI, upn: "someone@contoso.com"),
            account(msalId, .msal)
        ])
        #expect(map.isEmpty)
    }

    @Test func cliAloneOrMSALAloneStaysActive() {
        // Also the case once the MSAL account is removed: the CLI account is active again.
        #expect(AccountSupersede.superseded([account(cliId, .azureCLI)]).isEmpty)
        #expect(AccountSupersede.superseded([account(msalId, .msal)]).isEmpty)
    }

    @Test func msalNeverSupersedesAnotherMSAL() {
        let second = UUID()
        #expect(AccountSupersede.superseded([account(msalId, .msal), account(second, .msal)]).isEmpty)
    }

    @Test func resolvesFavoriteIdsOntoTheSupersedingAccount() {
        let map = [cliId: msalId]
        #expect(AccountSupersede.resolve(eligibleRoleId: "\(cliId.uuidString)|sched-1", superseded: map)
                == "\(msalId.uuidString)|sched-1")
        // ARM schedule ids are paths: only the account prefix changes.
        #expect(AccountSupersede.resolve(eligibleRoleId: "\(cliId.uuidString)|/subs/x/sched", superseded: map)
                == "\(msalId.uuidString)|/subs/x/sched")
        let untouched = "\(msalId.uuidString)|sched-1"
        #expect(AccountSupersede.resolve(eligibleRoleId: untouched, superseded: map) == untouched)
        #expect(AccountSupersede.resolve(eligibleRoleId: "garbage", superseded: map) == "garbage")
    }

    // MARK: Merge

    private let identity = AccountSupersede.identity(tenantId: "tenant-1", upn: "v.admin@contoso.com")

    private func row(_ id: String, _ name: String, scope: String = "/", source: RoleSource = .entraRole,
                     type: AssignmentType, endAt: Date? = nil, identity: String? = nil) -> AssignmentFacts {
        AssignmentFacts(id: id, identity: identity ?? self.identity, source: source, roleName: name, scope: scope,
                        type: type, endAt: endAt)
    }

    @Test func activationAndPermanentOfSameRoleBecomeOneActivationRow() {
        let end = Date.now + 3600
        let merged = RoleMerge.merge([
            row("perm", "License Administrator", type: .assigned),
            row("act", "License Administrator", type: .activated, endAt: end)
        ])
        #expect(merged.count == 1)
        #expect(merged[0].primaryId == "act")
        #expect(merged[0].type == .activated)
        #expect(merged[0].alsoPermanent)
        #expect(Set(merged[0].memberIds) == ["perm", "act"])
    }

    @Test func nameAndScopeMatchIgnoreCaseAndSpaces() {
        let merged = RoleMerge.merge([
            row("a", "User Administrator ", scope: "/SUBSCRIPTIONS/S1", type: .activated, endAt: .now + 60),
            row("b", "user administrator", scope: "/subscriptions/s1", type: .assigned)
        ])
        #expect(merged.count == 1)
    }

    @Test func differentScopeSourceOrIdentityStaySeparate() {
        let merged = RoleMerge.merge([
            row("a", "Reader", scope: "/s1", source: .azureResource, type: .activated, endAt: .now + 60),
            row("b", "Reader", scope: "/s2", source: .azureResource, type: .assigned),
            row("c", "Reader", scope: "/s1", source: .entraRole, type: .assigned),
            row("d", "Reader", scope: "/s1", source: .azureResource, type: .assigned, identity: "other|someone")
        ])
        #expect(merged.map(\.primaryId) == ["a", "b", "c", "d"])
        #expect(merged.allSatisfy { !$0.alsoPermanent })
    }

    @Test func twoPermanentAssignmentsOfSameRoleAreOneRow() {
        let merged = RoleMerge.merge([row("p1", "Global Reader", type: .assigned), row("p2", "Global Reader", type: .assigned)])
        #expect(merged.count == 1)
        #expect(merged[0].primaryId == "p1")
        #expect(merged[0].type == .assigned)
        #expect(!merged[0].alsoPermanent)   // only permanent: nothing to add
    }

    @Test func activationEndingLastWins() {
        let merged = RoleMerge.merge([
            row("short", "Contributor", type: .activated, endAt: .now + 60),
            row("long", "Contributor", type: .activated, endAt: .now + 7200)
        ])
        #expect(merged.count == 1)
        #expect(merged[0].primaryId == "long")
        #expect(!merged[0].alsoPermanent)
    }

    @Test func definitionIdTakesPrecedenceOverName() {
        let renamed = [
            AssignmentFacts(id: "a", identity: identity, source: .entraRole, roleDefinitionId: "def-1", roleName: "Old name",
                            scope: "/", type: .activated, endAt: .now + 60),
            AssignmentFacts(id: "b", identity: identity, source: .entraRole, roleDefinitionId: "DEF-1", roleName: "New name",
                            scope: "/", type: .assigned, endAt: nil)
        ]
        #expect(RoleMerge.merge(renamed).count == 1)
    }

    @Test func keepsTheOrderOfFirstRows() {
        let merged = RoleMerge.merge([
            row("x", "B role", type: .assigned), row("y", "A role", type: .assigned), row("z", "B role", type: .assigned)
        ])
        #expect(merged.map(\.primaryId) == ["x", "y"])
    }

    // MARK: Eligible already held

    @Test func eligibleRoleHeldByLinkOrByKey() {
        let key = RoleMerge.key(identity: identity, source: .entraRole, roleDefinitionId: nil,
                                roleName: "User Administrator", scope: "/")
        let permanent = row("p", "user administrator", type: .assigned)
        #expect(RoleMerge.isHeld(eligibleRoleId: "e1", key: key, linkedEligibleIds: [], heldKeys: [permanent.key]))
        #expect(RoleMerge.isHeld(eligibleRoleId: "e1", key: "other", linkedEligibleIds: ["e1"], heldKeys: []))
        #expect(!RoleMerge.isHeld(eligibleRoleId: "e1", key: key, linkedEligibleIds: ["e2"], heldKeys: ["other"]))
    }
}
