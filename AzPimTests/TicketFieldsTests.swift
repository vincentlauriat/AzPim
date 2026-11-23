@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Ticket fields (1.0 item 7) through the store's real ARM and Graph clients: both fields reach the request body.
@MainActor
struct TicketRequestTests {
    let input = ActivationInput(duration: "PT1H", justification: "Incident 42", ticketNumber: " INC42 ", ticketSystem: "ServiceNow")
    let expected = ["ticketNumber": "INC42", "ticketSystem": "ServiceNow"]

    struct Run {
        let transport: FakeTransport
        let harness: Harness
        let role: EligibleRole
    }

    /// Activates `role` (built on the harness account) through real clients on `transport`.
    private func activate(answer: FakeTransport.Answer, role make: (Account) -> EligibleRole) async throws -> Run {
        let harness = try Harness()
        let (account, _) = harness.addAccount(.msal)
        let transport = FakeTransport(posts: [answer])
        harness.store.makeSources = { _, token, _ in PIMService.sources(token: token, directory: true, transport: transport) }
        let role = make(account)
        harness.context.insert(role)
        let status = await harness.store.activate(role, input: input, refreshAfter: false)
        #expect(status == .provisioned)
        return Run(transport: transport, harness: harness, role: role)
    }

    @Test func armRequestCarriesTheSystemAndTheNumber() async throws {
        let run = try await activate(
            answer: .init(status: 201, json: ["name": "req-1", "properties": ["status": "Provisioned"]])) { account in
            EligibleRole(id: "/subscriptions/s1/providers/Microsoft.Authorization/roleEligibilitySchedules/sch1",
                         account: account, source: .azureResource,
                         roleDefinitionId: "/subscriptions/s1/providers/Microsoft.Authorization/roleDefinitions/rd1",
                         roleName: "Contributor", scope: "/subscriptions/s1", scopeName: "Sub", scopeType: "subscription")
        }
        let properties = try #require(run.transport.bodies.first?["properties"] as? [String: Any])
        #expect(properties["ticketInfo"] as? [String: String] == expected)
        #expect(run.transport.postURLs.first?.path.contains("roleAssignmentScheduleRequests") == true)
        // Accepted: the system is remembered for the tenant, the number for the role.
        #expect(run.harness.store.ticketSystem(for: run.role) == "ServiceNow")
        #expect(run.harness.store.recentTicket(for: [run.role]) == "INC42")
    }

    @Test func entraRequestCarriesTheSystemAndTheNumber() async throws {
        let transport = try await activate(
            answer: .init(status: 201, json: ["id": "req-1", "status": "Provisioned"])) { account in
            EligibleRole(id: "g1", account: account, source: .entraRole, roleDefinitionId: "rd-g1",
                         roleName: "Global Reader", scope: "/", scopeName: "Directory", scopeType: "directory")
        }.transport
        #expect(transport.bodies.first?["ticketInfo"] as? [String: String] == expected)
        #expect(transport.postURLs.first?.path.hasSuffix("/roleManagement/directory/roleAssignmentScheduleRequests") == true)
    }

    @Test func groupRequestCarriesTheSystemAndTheNumber() async throws {
        let transport = try await activate(
            answer: .init(status: 201, json: ["id": "req-1", "status": "Provisioned"])) { account in
            EligibleRole(id: "gs1", account: account, source: .pimGroup, roleDefinitionId: "member",
                         roleName: "Member", scope: "group-1", scopeName: "SG-Ops", scopeType: "group")
        }.transport
        #expect(transport.bodies.first?["ticketInfo"] as? [String: String] == expected)
        #expect(transport.postURLs.first?.path.hasSuffix("/privilegedAccess/group/assignmentScheduleRequests") == true)
    }

    /// A refused request remembers nothing.
    @Test func aRefusalRemembersNothing() async throws {
        let harness = try Harness()
        let (account, _) = harness.addAccount(.msal)
        let transport = FakeTransport(posts: [.init(status: 403, json: ["error": ["code": "Forbidden", "message": "no"]])])
        harness.store.makeSources = { _, token, _ in PIMService.sources(token: token, directory: true, transport: transport) }
        let role = EligibleRole(id: "g1", account: account, source: .entraRole, roleDefinitionId: "rd-g1",
                                roleName: "Global Reader", scope: "/", scopeName: "Directory", scopeType: "directory")
        harness.context.insert(role)
        #expect(await harness.store.activate(role, input: input, refreshAfter: false) == nil)
        #expect(harness.store.ticketSystem(for: role).isEmpty)
        #expect(harness.store.recentTicket(for: [role]).isEmpty)
    }
}

/// What the sheets prefill, and what the favorites and the quick path send.
@MainActor
struct TicketPrefillTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource
    let entra: FakeSource
    let ticketPolicy = RolePolicy(maxDuration: "PT8H", requiresJustification: true, requiresTicket: true)

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount(sources: [.azureResource, .entraRole])
        self.account = account
        arm = sources[0]
        entra = sources[1]
        await arm.set(eligible: [Fixture.eligibility("e1")])
        await arm.set(policy: .success(ticketPolicy))
        await entra.set(eligible: [Fixture.eligibility("g1", source: .entraRole, role: "Global Reader")])
        await entra.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await harness.refresh()
    }

    private func ticketRole() throws -> EligibleRole { try #require(harness.role(account, "e1")) }
    private func openRole() throws -> EligibleRole { try #require(harness.role(account, "g1")) }

    private func remember(_ number: String, system: String = "ServiceNow", for role: EligibleRole, hoursAgo: Double) {
        harness.store.rememberTicket(ActivationInput(duration: "PT1H", justification: "", ticketNumber: number, ticketSystem: system),
                                     for: role, at: .now - hoursAgo * 3600)
    }

    /// Same incident under 8 hours; after that, an empty number. The tenant's system stays.
    @Test func numberWithinEightHoursOnly() throws {
        let role = try ticketRole()
        remember("INC1", for: role, hoursAgo: 7.9)
        #expect(harness.store.recentTicket(for: [role]) == "INC1")
        remember("INC1", for: role, hoursAgo: 8.1)
        #expect(harness.store.recentTicket(for: [role]) == "")
        #expect(harness.store.ticketSystem(for: role) == "ServiceNow")
        // Another role of the same tenant: the system, never the number.
        let other = try openRole()
        #expect(harness.store.recentTicket(for: [other]) == "")
        #expect(harness.store.ticketSystem(for: other) == "ServiceNow")
    }

    @Test func systemIsPerTenant() async throws {
        remember("INC1", system: "Jira", for: try ticketRole(), hoursAgo: 1)
        let (other, sources) = harness.addAccount(objectId: "oid-2", tenantId: "tenant-2", sortOrder: 1)
        await sources[0].set(eligible: [Fixture.eligibility("x1")])
        await harness.refresh()
        let foreign = try #require(harness.role(other, "x1"))
        #expect(harness.store.ticketSystem(for: foreign) == "")
    }

    /// The quick path never sends a remembered ticket: the sheet opens.
    @Test func quickPathStillOpensTheSheet() async throws {
        let role = try ticketRole()
        remember("INC1", for: role, hoursAgo: 1)
        role.lastJustification = "Audit"
        #expect(await harness.store.quickActivate(role) == .needsSheet)
        #expect(await arm.activateCount == 0)
    }

    /// One grouped sheet: the ticket goes to the ticket role, the justification to both.
    @Test func groupedFavoriteSendsTheAnswersToEveryRole() async throws {
        let favorite = Favorite(name: "Incident", items: [FavoriteItem(eligibleRoleId: try ticketRole().id, duration: "PT1H"),
                                                          FavoriteItem(eligibleRoleId: try openRole().id, duration: "PT1H")])
        harness.context.insert(favorite)
        #expect(await harness.store.favoriteNeeds(favorite) == FavoriteNeeds(justification: true, ticket: true))
        let answers = FavoriteAnswers(justification: "Incident 42", ticketSystem: "ServiceNow", ticketNumber: "INC42")
        await harness.store.run(favorite, answers: answers)
        #expect(harness.records().map(\.status) == [.provisioned, .provisioned])
        #expect(await arm.inputs == [ActivationInput(duration: "PT1H", justification: "Incident 42", ticketNumber: "INC42",
                                                     ticketSystem: "ServiceNow")])
        #expect(await entra.inputs == [ActivationInput(duration: "PT1H", justification: "Incident 42")])
        // Remembered from the grouped sheet too.
        #expect(harness.store.recentTicket(for: [try ticketRole()]) == "INC42")
    }

    /// Without the sheet (link, Shortcuts) a ticket role is not sent, even with a recent ticket remembered; the others
    /// are, and the summary says which one failed.
    @Test func runWithoutAnswersRefusesTheTicketRole() async throws {
        remember("INC1", for: try ticketRole(), hoursAgo: 1)
        let favorite = Favorite(name: "Incident", items: [FavoriteItem(eligibleRoleId: try ticketRole().id, duration: "PT1H"),
                                                          FavoriteItem(eligibleRoleId: try openRole().id, duration: "PT1H")])
        harness.context.insert(favorite)
        await harness.store.run(favorite)
        #expect(await arm.activateCount == 0)
        #expect(await entra.activateCount == 1)
        #expect(harness.records().map(\.roleName) == ["Global Reader"])
    }

    /// Nothing to ask: no sheet.
    @Test func favoriteWithoutTicketNeedsNothing() async throws {
        let favorite = Favorite(name: "Open", items: [FavoriteItem(eligibleRoleId: try openRole().id, duration: "PT1H")])
        harness.context.insert(favorite)
        #expect(await harness.store.favoriteNeeds(favorite) == FavoriteNeeds())
    }

    /// Pruned with the durations: roles no longer cached, numbers older than 8 h, tenants signed out.
    @Test func pruneDropsGoneRolesAndOldNumbers() async throws {
        remember("INC1", for: try ticketRole(), hoursAgo: 1)
        remember("INC2", for: try openRole(), hoursAgo: 9)
        await arm.set(eligible: [])
        await harness.refresh()
        #expect(harness.store.ticketMemory.loadNumbers().isEmpty)
        #expect(harness.store.ticketMemory.loadSystems().count == 1)
        harness.context.delete(account)
        try harness.context.save()
        harness.store.pruneDurations()
        #expect(harness.store.ticketMemory.loadSystems().isEmpty)
    }
}
