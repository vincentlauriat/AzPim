#if DEBUG
import AzPimCore
import Foundation
import SwiftData

/// Debug only: the fixture data of the Mac snapshots (`SnapshotRunner`) and of the iPhone demo mode
/// (`AZPIM_DEMO=1`), so the UI can be checked without a tenant.
@MainActor
enum DemoFixtures {
    /// One person signed in twice (Azure CLI and Microsoft, same tenant and UPN in another case), Azure roles held by
    /// both, Entra roles of which one is activated and also assigned permanently through a group, one held only
    /// permanently, and PIM groups. Before the dedup this rendered every Azure role twice and both Entra roles twice.
    /// `azureCLI` false (iPhone, no Azure CLI): the Microsoft sign-in only, the favorites saved on it.
    static func add(context: ModelContext, azureCLI: Bool = true) {
        let cli = Account(mode: .azureCLI, upn: "V.Admin@Contoso.com", objectId: "oid-1", tenantId: "TENANT-CONTOSO",
                          tenantName: "Contoso", sortOrder: 0)
        let msal = Account(mode: .msal, upn: "v.admin@contoso.com", objectId: "oid-1", tenantId: "tenant-contoso",
                           tenantName: "Contoso", sortOrder: 1)
        msal.directoryAccess = .enabled
        let accounts = azureCLI ? [cli, msal] : [msal]
        for account in accounts {
            account.lastRefreshAt = .now
            context.insert(account)
        }
        // Azure resource roles, cached under both accounts (the CLI copies must not show).
        for account in accounts {
            let fixtures = Fixtures(context: context, account: account)
            let reader = fixtures.eligible("e-reader", .azureResource, "Reader", "/providers/mg/root",
                                           "Tenant Root Group")
            let contributor = fixtures.eligible("e-contrib", .azureResource, "Contributor", "/subs/s1/rg/app-prod",
                                                "rg-app-prod-weu001")
            _ = fixtures.eligible("e-kvadmin", .azureResource, "Key Vault Administrator", "/subs/s1/kv/app-prod",
                                  "kv-app-prod-weu001")
            fixtures.assignment("a-reader", .azureResource, "Reader", "/providers/mg/root", "Tenant Root Group",
                                started: 18 * 60, ends: 42 * 60, role: reader)
            fixtures.assignment("a-contrib", .azureResource, "Contributor", "/subs/s1/rg/app-prod",
                                "rg-app-prod-weu001", started: 7 * 3600, ends: 3 * 3600 + 16 * 60, role: contributor)
            fixtures.assignment("p-kvso", .azureResource, "Key Vault Secrets Officer", "/subs/s1/kv/app-dev",
                                "kv-app-dev-weu001")
            if account === msal { addEntraAndGroups(fixtures) }
        }
        // Saved on the CLI account: resolves onto the MSAL one.
        let favoriteRole = "\((azureCLI ? cli : msal).id.uuidString)|e-contrib"
        context.insert(Favorite(name: "Morning deploy", items: [FavoriteItem(eligibleRoleId: favoriteRole, duration: "PT4H")]))
        context.insert(Favorite(name: "Audit", items: [FavoriteItem(eligibleRoleId: "\(msal.id.uuidString)|e-reader",
                                                                    duration: "PT1H")], sortOrder: 1))
        addHistory(account: msal, context: context)
    }

    private static func addEntraAndGroups(_ fixtures: Fixtures) {
        let license = fixtures.eligible("e-license", .entraRole, "License Administrator", "/", "Directory")
        _ = fixtures.eligible("e-useradmin", .entraRole, "User Administrator", "/", "Directory")
        _ = fixtures.eligible("e-globalreader", .entraRole, "Global Reader", "/", "Directory")
        _ = fixtures.eligible("e-secreader", .entraRole, "Security Reader", "/", "Directory")
        // Activated through PIM and also assigned permanently via a group: one row, "also permanent".
        fixtures.assignment("a-license", .entraRole, "License Administrator", "/", "Directory",
                            started: 55 * 60, ends: 65 * 60, role: license)
        fixtures.assignment("p-license", .entraRole, "License Administrator", "/", "Directory")
        // Held permanently only: shown under Permanent, not offered as eligible.
        fixtures.assignment("p-useradmin", .entraRole, "User Administrator", "/", "Directory")
        let sql = fixtures.eligible("e-sql", .pimGroup, "Member", "g-sql", "sg-pim-sql-admins")
        _ = fixtures.eligible("e-ops", .pimGroup, "Member", "g-ops", "sg-pim-prod-operators")
        _ = fixtures.eligible("e-glass", .pimGroup, "Owner", "g-glass", "sg-pim-break-glass")
        fixtures.assignment("a-sql", .pimGroup, "Member", "g-sql", "sg-pim-sql-admins",
                            started: 35 * 60, ends: 25 * 60, role: sql)
    }

    private struct Fixtures {
        let context: ModelContext
        let account: Account

        func eligible(_ id: String, _ source: RoleSource, _ name: String, _ scope: String,
                      _ scopeName: String) -> EligibleRole {
            let role = EligibleRole(id: id, account: account, source: source, roleDefinitionId: "def-\(name)", roleName: name,
                                    scope: scope, scopeName: scopeName, scopeType: source == .entraRole ? "directory" : "scope")
            context.insert(role)
            return role
        }

        /// An activation when `ends` is given (seconds from now), else a permanent assignment.
        func assignment(_ id: String, _ source: RoleSource, _ name: String, _ scope: String,
                        _ scopeName: String, started: TimeInterval = 86_400, ends: TimeInterval? = nil,
                        role: EligibleRole? = nil) {
            context.insert(ActiveAssignment(id: id, account: account, source: source, roleName: name, scope: scope,
                                            scopeName: scopeName, assignmentType: ends == nil ? .assigned : .activated,
                                            startAt: .now - started, endAt: ends.map { .now + $0 }, eligibleRole: role))
        }
    }

    private static func addHistory(account: Account, context: ModelContext) {
        struct Sample {
            let roleId: String, name: String, scope: String, action: ActivationAction, ago: TimeInterval
            let justification: String, took: TimeInterval
        }
        let prefix = account.id.uuidString + "|"
        let samples = [
            Sample(roleId: "e-reader", name: "Reader", scope: "Tenant Root Group", action: .activate, ago: 18 * 60,
                   justification: "Audit of the tenant root policies", took: 14),
            Sample(roleId: "e-license", name: "License Administrator", scope: "Directory", action: .activate, ago: 55 * 60,
                   justification: "Assign licenses to the new hires", took: 9),
            Sample(roleId: "e-contrib", name: "Contributor", scope: "rg-app-prod-weu001", action: .activate, ago: 7 * 3600,
                   justification: "Deploy release 2.4 to production", took: 21),
            Sample(roleId: "e-reader", name: "Reader", scope: "Tenant Root Group", action: .deactivate, ago: 26 * 3600,
                   justification: "", took: 0)
        ]
        for sample in samples {
            let record = ActivationRecord(account: account, eligibleRoleId: prefix + sample.roleId, roleName: sample.name,
                                          scopeName: sample.scope, source: .azureResource, action: sample.action,
                                          requestedDuration: sample.action == .activate ? "PT1H" : nil,
                                          justification: sample.justification.isEmpty ? nil : sample.justification,
                                          panelOpenedAt: sample.action == .activate ? .now - sample.ago - sample.took : nil)
            record.sentAt = .now - sample.ago
            record.status = .provisioned
            record.completedAt = .now - sample.ago + max(sample.took - 8, 1)
            context.insert(record)
        }
    }
}
#endif
