import Foundation
import SwiftData
import Testing
@testable import AzPimCore

@MainActor
struct ModelTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try AzPimStore.makeContainer(inMemory: true)
    }

    @Test func seedCreatesSingleSettingsRow() throws {
        let first = try AzPimStore.settings(in: context)
        let second = try AzPimStore.settings(in: context)
        #expect(first === second)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
        #expect(first.refreshIntervalMinutes == 5)
        #expect(first.notificationLeadMinutes == 15)
        #expect(first.historyRetentionDays == 90)
        #expect(first.menuBarStyle == .iconCountTime)
    }

    @Test func accountDefaultsDependOnMode() {
        let cli = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        let msal = Account(mode: .msal, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        #expect(cli.directoryAccess == .notApplicable)
        #expect(msal.directoryAccess == .notRequested)
        #expect(cli.identityKey != msal.identityKey)
    }

    @Test func everyEntityRoundTrips() throws {
        let account = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1", tenantName: "Contoso")
        context.insert(account)
        let role = EligibleRole(id: "sched-1", account: account, source: .azureResource,
                                roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/r",
                                roleName: "Reader", scope: "/providers/Microsoft.Management/managementGroups/t1",
                                scopeName: "Tenant Root Group", scopeType: "managementgroup")
        context.insert(role)
        let active = ActiveAssignment(id: "inst-1", account: account, source: .azureResource, roleName: "Reader",
                                      scope: role.scope, scopeName: role.scopeName, assignmentType: .activated,
                                      startAt: .now, endAt: .now.addingTimeInterval(3600), eligibleRole: role)
        context.insert(active)
        context.insert(Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: "sched-1", duration: "PT4H")]))
        let record = ActivationRecord(account: account, eligibleRoleId: "sched-1", roleName: "Reader",
                                      scopeName: "Tenant Root Group", source: .azureResource, action: .activate,
                                      requestedDuration: "PT4H", panelOpenedAt: .now.addingTimeInterval(-8))
        record.status = .provisioned
        record.completedAt = .now
        context.insert(record)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(fetched.eligibleRoles.count == 1)
        #expect(fetched.activeAssignments.first?.eligibleRole?.roleName == "Reader")
        #expect(try context.fetch(FetchDescriptor<Favorite>()).first?.items.first?.duration == "PT4H")
        #expect(fetched.eligibleRoles.first?.remoteId == "sched-1")
        #expect(fetched.eligibleRoles.first?.id == "\(account.id.uuidString)|sched-1")
        let time = try #require(fetched.records.first?.timeToActivation)
        #expect(time > 7 && time < 10)
    }

    @Test func sameRoleUnderTwoAccountsDoesNotCollide() throws {
        let cli = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o", tenantId: "t")
        let msal = Account(mode: .msal, upn: "a@x.com", objectId: "o", tenantId: "t")
        context.insert(cli)
        context.insert(msal)
        for account in [cli, msal] {
            context.insert(EligibleRole(id: "same-schedule", account: account, source: .azureResource, roleDefinitionId: "d",
                                        roleName: "Reader", scope: "/", scopeName: "Root", scopeType: "managementgroup"))
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<EligibleRole>()) == 2)
        #expect(cli.eligibleRoles.count == 1 && msal.eligibleRoles.count == 1)
    }

    @Test func deletingAccountCascades() throws {
        let account = Account(mode: .msal, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        context.insert(account)
        context.insert(EligibleRole(id: "s", account: account, source: .entraRole, roleDefinitionId: "d",
                                    roleName: "Application Administrator", scope: "/", scopeName: "Directory",
                                    scopeType: "directory"))
        try context.save()
        context.delete(account)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<EligibleRole>()) == 0)
    }

    /// Pending badge and favorite skip: waiting for approval, or sent with a request id in the last 15 minutes.
    @Test func waitingRequests() throws {
        let account = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        context.insert(account)
        // "c" was sent but never got a request id (app quit mid-flight): not waiting.
        let rows: [(String, RequestStatus)] = [("a", .pendingApproval), ("b", .sent), ("c", .sent), ("d", .failed),
                                               ("e", .sent)]
        for (role, status) in rows {
            let record = ActivationRecord(account: account, eligibleRoleId: role, roleName: role, scopeName: "s",
                                          source: .azureResource, action: .activate)
            record.status = status
            record.remoteRequestId = role == "c" ? nil : "req-\(role)"
            // "e" was sent 20 minutes ago and its status could never be read: no longer blocks the row.
            if role == "e" { record.sentAt = Date.now.addingTimeInterval(-20 * 60) }
            context.insert(record)
        }
        try context.save()
        // Same fetch as the panel's query, then the core rule.
        let candidates = try context.fetch(FetchDescriptor<ActivationRecord>(predicate: #Predicate {
            $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent"
        }))
        #expect(Set(candidates.filter { $0.isWaiting() }.map(\.eligibleRoleId)) == ["a", "b"])
    }

    /// A cached activation past its end date must not count as active (panel, favorites, Extend).
    @Test func expiredActivationIsNotLive() {
        let account = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        let now = Date(timeIntervalSince1970: 1_000_000)
        func assignment(endAt: Date?) -> ActiveAssignment {
            ActiveAssignment(id: "i", account: account, source: .azureResource, roleName: "Reader", scope: "/s",
                             scopeName: "s", assignmentType: .activated, startAt: now.addingTimeInterval(-3600), endAt: endAt)
        }
        #expect(assignment(endAt: now.addingTimeInterval(60)).isLive(at: now))
        #expect(!assignment(endAt: now.addingTimeInterval(-1)).isLive(at: now))
        #expect(!assignment(endAt: now).isLive(at: now))
        #expect(assignment(endAt: nil).isLive(at: now))
    }
}
