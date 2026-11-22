import Foundation
import Testing
@testable import AzPimCore

/// One account per identity (supersede) and one row per role (merge).
struct RoleDedupTests {
    private let cliId = UUID()
    private let msalId = UUID()
    private let all = Set(RoleSource.allCases)

    private func cli(tenant: String = "tenant-1", oid: String = "oid-1", upn: String = "v.admin@contoso.com",
                     id: UUID? = nil) -> AccountFacts {
        AccountFacts(id: id ?? cliId, mode: .azureCLI, tenantId: tenant, objectId: oid, upn: upn)
    }

    private func msal(loaded: Set<RoleSource> = [.azureResource], tenant: String = "tenant-1", oid: String = "oid-1",
                      upn: String = "v.admin@contoso.com", id: UUID? = nil) -> AccountFacts {
        AccountFacts(id: id ?? msalId, mode: .msal, tenantId: tenant, objectId: oid, upn: upn,
                     sources: Set(RoleSource.allCases), loaded: loaded)
    }

    // MARK: Supersede

    @Test func msalSupersedesCLIOnceItLoadedAzureResources() {
        let result = AccountSupersede.supersession([cli(tenant: "TENANT-1", oid: "OID-1"), msal()])
        #expect(result.replacedBy == [cliId: msalId])
        #expect(result.hides(cliId, .azureResource))
        #expect(result.isRetired(cliId))
        #expect(!result.hides(msalId, .azureResource))
    }

    @Test func cliStaysUntilMSALLoadedTheSource() {
        // Signed in but nothing loaded yet, or only Entra loaded (ARM keeps failing): the CLI Azure roles stay.
        for loaded in [Set<RoleSource>(), [.entraRole, .pimGroup]] {
            let result = AccountSupersede.supersession([cli(), msal(loaded: loaded)])
            #expect(result == .none)
            #expect(!result.hides(cliId, .azureResource))
        }
    }

    @Test func partialSupersedeDoesNotRetire() {
        let both = AccountFacts(id: cliId, mode: .azureCLI, tenantId: "tenant-1", objectId: "oid-1",
                                upn: "v.admin@contoso.com", sources: [.azureResource, .entraRole])
        let result = AccountSupersede.supersession([both, msal(loaded: [.azureResource])])
        #expect(result.hides(cliId, .azureResource))
        #expect(!result.hides(cliId, .entraRole))
        #expect(!result.isRetired(cliId))
    }

    @Test func matchesOnObjectIdThenUPN() {
        // Same object id, UPN renamed: same person.
        #expect(AccountSupersede.supersession([cli(upn: "old@contoso.com"), msal()]).isRetired(cliId))
        // No object id on one side: the UPN decides, ignoring case.
        #expect(AccountSupersede.supersession([cli(oid: "", upn: "V.Admin@Contoso.com"), msal()]).isRetired(cliId))
        // Different object id and UPN: someone else.
        #expect(AccountSupersede.supersession([cli(oid: "oid-2", upn: "other@contoso.com"), msal()]) == .none)
        // Other tenant: never.
        #expect(AccountSupersede.supersession([cli(tenant: "tenant-2"), msal()]) == .none)
    }

    @Test func cliAloneOrMSALAloneStaysActive() {
        // Also the case once the MSAL account is removed: the CLI account is active again.
        #expect(AccountSupersede.supersession([cli()]) == .none)
        #expect(AccountSupersede.supersession([msal()]) == .none)
        #expect(AccountSupersede.supersession([msal(), msal(id: UUID())]) == .none)
    }

    @Test func resolvesIdsOntoTheSupersedingAccountForHiddenSourcesOnly() {
        let result = AccountSupersede.supersession([cli(), msal()])
        #expect(result.resolve(eligibleRoleId: "\(cliId.uuidString)|sched-1", source: .azureResource)
                == "\(msalId.uuidString)|sched-1")
        // ARM schedule ids are paths: only the account prefix changes.
        #expect(result.resolve(eligibleRoleId: "\(cliId.uuidString)|/subs/x/sched", source: .azureResource)
                == "\(msalId.uuidString)|/subs/x/sched")
        let notHidden = "\(cliId.uuidString)|sched-1"
        #expect(result.resolve(eligibleRoleId: notHidden, source: .entraRole) == notHidden)
        let untouched = "\(msalId.uuidString)|sched-1"
        #expect(result.resolve(eligibleRoleId: untouched, source: .azureResource) == untouched)
        #expect(result.resolve(eligibleRoleId: "garbage", source: .azureResource) == "garbage")
    }

    // MARK: Merge

    private let identity = AccountSupersede.identity(tenantId: "tenant-1", objectId: "oid-1", upn: "v.admin@contoso.com")

    private func row(_ id: String, _ name: String, scope: String = "/", source: RoleSource = .entraRole,
                     type: AssignmentType, endAt: Date? = nil, identity: String? = nil, linked: Bool = false) -> AssignmentFacts {
        AssignmentFacts(id: id, identity: identity ?? self.identity, source: source, roleName: name, scope: scope,
                        type: type, endAt: endAt, linked: linked)
    }

    @Test func activationAndPermanentOfSameRoleBecomeOneActivationRow() {
        let merged = RoleMerge.merge([
            row("perm", "License Administrator", type: .assigned),
            row("act", "License Administrator", type: .activated, endAt: .now + 3600, linked: true)
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

    @Test func fallbackNamesAreNeverMerged() {
        let merged = RoleMerge.merge([
            row("a", "Entra role", type: .activated, endAt: .now + 60),
            row("b", "Entra role", type: .assigned),
            row("c", "Role", source: .azureResource, type: .assigned),
            row("d", "role", source: .azureResource, type: .assigned)
        ])
        #expect(merged.map(\.primaryId) == ["a", "b", "c", "d"])
    }

    @Test func twoPermanentAssignmentsOfSameRoleAreOneRow() {
        let merged = RoleMerge.merge([row("p1", "Global Reader", type: .assigned), row("p2", "Global Reader", type: .assigned)])
        #expect(merged.count == 1)
        #expect(merged[0].primaryId == "p1")
        #expect(merged[0].type == .assigned)
        #expect(!merged[0].alsoPermanent)   // only permanent: nothing to add
    }

    @Test func linkedActivationWinsThenTheOneEndingLast() {
        let byEnd = RoleMerge.merge([
            row("short", "Contributor", type: .activated, endAt: .now + 60),
            row("long", "Contributor", type: .activated, endAt: .now + 7200)
        ])
        #expect(byEnd.count == 1)
        #expect(byEnd[0].primaryId == "long")
        let byLink = RoleMerge.merge([
            row("linked", "Contributor", type: .activated, endAt: .now + 60, linked: true),
            row("unlinked", "Contributor", type: .activated, endAt: .now + 7200)
        ])
        #expect(byLink[0].primaryId == "linked")
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
                                roleName: "User Administrator", scope: "/") ?? ""
        let permanent = row("p", "user administrator", type: .assigned)
        #expect(RoleMerge.isHeld(eligibleRoleId: "e1", key: key, linkedEligibleIds: [], heldKeys: [permanent.key]))
        #expect(RoleMerge.isHeld(eligibleRoleId: "e1", key: "other", linkedEligibleIds: ["e1"], heldKeys: []))
        #expect(!RoleMerge.isHeld(eligibleRoleId: "e1", key: key, linkedEligibleIds: ["e2"], heldKeys: ["other"]))
    }

    @Test func fallbackNameIsNeverHeldByKey() {
        #expect(RoleMerge.key(identity: identity, source: .entraRole, roleDefinitionId: nil, roleName: "Entra role",
                              scope: "/") == nil)
        let first = row("p1", "Entra role", type: .assigned), second = row("p2", "Entra role", type: .assigned)
        #expect(first.key != second.key)
    }
}
