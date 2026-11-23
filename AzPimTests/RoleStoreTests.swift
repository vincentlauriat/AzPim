@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// RoleStore against fake PIM sources: Extend, favorites, polling, accounts and notifications.
@MainActor
struct ExtendTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource
    let eligibility = Fixture.eligibility("e1")

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [eligibility], assignments: [Fixture.activation(eligibility, instance: "i1")])
        await harness.refresh()
        // Extend reuses the justification of the request that made the activation (i1 started 1 h ago).
        let record = ActivationRecord(account: account, eligibleRoleId: "\(account.id.uuidString)|e1", roleName: "Contributor",
                                      scopeName: "Scope e1", source: .azureResource, action: .activate,
                                      requestedDuration: "PT1H", justification: "Release")
        record.status = .provisioned
        record.sentAt = .now.addingTimeInterval(-3600)
        harness.context.insert(record)
    }

    var roleId: String { "\(account.id.uuidString)|e1" }

    @Test func extendSucceedsAtOnce() async throws {
        let text = await harness.store.extend(eligibleRoleId: roleId)
        #expect(text.hasPrefix("Extended until"))
        #expect(harness.sleeps.isEmpty)
        #expect(await arm.deactivateCount == 1)
        #expect(await arm.activateCount == 1)
        let extend = harness.records().filter { $0.action == .extend }
        #expect(extend.map(\.status) == [.provisioned])
        #expect(harness.store.extending.isEmpty)
        #expect(harness.store.activeActivations().map(\.id) == ["\(account.id.uuidString)|e1-new-1"])
    }

    /// Azure still reports the old activation for a few seconds: wait 3 s and try again; the refusal leaves no record.
    @Test func extendRetriesWhileAzureReportsTheOldActivation() async throws {
        await arm.set(activate: [.failure(alreadyActive)], for: "e1")
        let text = await harness.store.extend(eligibleRoleId: roleId)
        #expect(text.hasPrefix("Extended until"))
        #expect(harness.sleeps == [.seconds(3)])
        #expect(await arm.activateCount == 2)
        #expect(harness.records().filter { $0.action == .extend }.map(\.status) == [.provisioned])
    }

    @Test func extendGivesUpAfterThreeWaits() async throws {
        await arm.set(activate: Array(repeating: .failure(alreadyActive), count: 4), for: "e1")
        let text = await harness.store.extend(eligibleRoleId: roleId)
        #expect(text.hasPrefix("Role deactivated; re-activation failed"))
        #expect(harness.sleeps == [.seconds(3), .seconds(6), .seconds(12)])
        #expect(await arm.activateCount == 4)
        // Only the last refusal stays in History.
        #expect(harness.records().filter { $0.action == .extend }.map(\.status) == [.failed])
        #expect(harness.store.rowErrors[roleId] != nil)
    }

    @Test func extendStopsWhenTheDeactivationFails() async throws {
        await arm.set(deactivate: .failure(PIMError.http(status: 500, code: nil, message: "Boom")))
        let text = await harness.store.extend(eligibleRoleId: roleId)
        #expect(text.hasPrefix("Couldn't extend: Boom"))
        #expect(text.hasSuffix("The role is still active."))
        #expect(await arm.activateCount == 0)
        #expect(harness.store.activeActivations().count == 1)
    }

    /// A refresh during the extension replaces the active row (new instance id): the new row is busy too.
    @Test func activeRowStaysBusyWhenARefreshReplacesIt() async throws {
        await arm.set(activate: [.failure(alreadyActive)], for: "e1")
        await arm.set(deactivate: .success(RequestOutcome(requestId: "d", status: .provisioned)), removes: false)
        var observed: [(id: String, busy: Bool)] = []
        let harness = harness, arm = arm, eligibility = eligibility
        harness.duringSleep = {
            await arm.set(assignments: [Fixture.activation(eligibility, instance: "i1-replaced")])
            await harness.refresh()
            observed = harness.store.activeActivations().map { ($0.id, harness.store.isBusy($0)) }
        }
        _ = await harness.store.extend(eligibleRoleId: roleId)
        #expect(observed.map(\.id) == ["\(account.id.uuidString)|i1-replaced"])
        #expect(observed.map(\.busy) == [true])
        #expect(!harness.store.activeActivations().isEmpty)
        #expect(harness.store.activeActivations().allSatisfy { !harness.store.isBusy($0) })
    }
}

@MainActor
struct RefreshTests {
    @Test func favoriteRunReportsEachRole() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let first = Fixture.eligibility("e1", role: "Reader"), second = Fixture.eligibility("e2", role: "Owner")
        await sources[0].set(eligible: [first, second])
        await sources[0].set(activate: [.failure(PIMError.http(status: 403, code: nil, message: "Not allowed"))], for: "e2")
        await harness.refresh()
        let favorite = Favorite(name: "Morning", items: [
            FavoriteItem(eligibleRoleId: "\(account.id.uuidString)|e1", justification: "Daily ops"),
            FavoriteItem(eligibleRoleId: "\(account.id.uuidString)|e2", justification: "Daily ops")
        ])
        harness.context.insert(favorite)
        let text = await harness.store.run(favorite)
        #expect(text.hasPrefix("1 of 2 activated"))
        #expect(text.contains("Owner"))
        #expect(harness.records().map(\.status).sorted { $0.rawValue < $1.rawValue } == [.failed, .provisioned])
        #expect(harness.store.favoriteToast?.text == text)
        #expect(harness.store.runningFavorites.isEmpty)
    }

    /// A request waiting for approval keeps being polled while the source it belongs to fails; the other source still
    /// lists its pending requests. Once the source answers, the decision is recorded and notified.
    @Test func pendingRequestSurvivesAFailedSource() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount(.msal, sources: [.azureResource, .entraRole])
        let arm = sources[0], entra = sources[1]
        let role = Fixture.eligibility("g1", source: .entraRole, role: "Global Reader")
        await entra.set(eligible: [role])
        await harness.refresh()
        let record = ActivationRecord(account: account, eligibleRoleId: "\(account.id.uuidString)|g1", roleName: "Global Reader",
                                      scopeName: "Directory", source: .entraRole, action: .activate)
        record.status = .pendingApproval
        record.remoteRequestId = "req-g1"
        harness.context.insert(record)

        await entra.fail(with: URLError(.notConnectedToInternet))
        await entra.set(requestStatus: .failure(URLError(.notConnectedToInternet)))
        await harness.refresh()
        #expect(RoleStore.needsPolling(record))
        #expect(record.status == .pendingApproval)
        #expect(harness.store.refreshErrors[account.id] == [.entraRole: .offline])
        #expect(harness.role(account, "g1") != nil)   // the failed source keeps its rows
        #expect(await arm.pendingCount == 1)
        #expect(await entra.pendingCount == 0)

        await entra.fail(with: nil)
        await entra.set(requestStatus: .success(.provisioned))
        await harness.refresh()
        #expect(record.status == .provisioned)
        #expect(!RoleStore.needsPolling(record))
        #expect(harness.center.immediate.map(\.title) == ["Request approved: Global Reader"])
        #expect(harness.center.immediate.map(\.body) == ["Directory — the role is active."])
    }

    /// A request refused by the approver (or failed, or canceled in the portal) is notified once as denied.
    @Test(arguments: [(RequestStatus.denied, "Request denied: Owner"), (.failed, "Request expired or failed: Owner"),
                      (.canceled, "Request canceled: Owner")])
    func refusedRequestIsNotifiedOnce(status: RequestStatus, title: String) async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1")])
        await harness.refresh()
        let record = ActivationRecord(account: account, eligibleRoleId: "\(account.id.uuidString)|e1", roleName: "Owner",
                                      scopeName: "rg-app", source: .azureResource, action: .activate)
        record.status = .pendingApproval
        record.remoteRequestId = "req-e1"
        harness.context.insert(record)

        await arm.set(requestStatus: .success(status))
        await harness.refresh()
        #expect(record.status == status)
        #expect(record.completedAt == nil)
        #expect(harness.center.immediate.map(\.title) == [title])
        #expect(harness.center.immediate.first?.body.hasPrefix("rg-app — ") == true)

        // Decided: no longer polled, never notified again.
        await harness.refresh()
        #expect(!RoleStore.needsPolling(record))
        #expect(harness.center.immediate.count == 1)
    }

    /// The user's own cancel, still in flight when the poll reads "canceled": never notified.
    @Test func ownCancelIsNotNotified() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1")])
        await harness.refresh()
        let record = ActivationRecord(account: account, eligibleRoleId: "\(account.id.uuidString)|e1", roleName: "Owner",
                                      scopeName: "rg-app", source: .azureResource, action: .activate)
        record.status = .pendingApproval
        record.remoteRequestId = "REQ-e1"
        harness.context.insert(record)

        await arm.set(requestStatus: .success(.canceled))
        harness.store.cancellingRequests.insert("req-e1")
        await harness.refresh()
        #expect(harness.center.immediate.isEmpty)
        #expect(record.status == .pendingApproval)

        // The cancel completes: the record is canceled locally and the poll stops.
        harness.store.cancellingRequests.removeAll()
        #expect(await harness.store.cancel(requestId: "REQ-e1", source: .azureResource, account: account) == nil)
        #expect(record.status == .canceled)
        await harness.refresh()
        #expect(harness.center.immediate.isEmpty)
        #expect(harness.store.cancellingRequests.isEmpty)
    }

    /// Still waiting: nothing is notified.
    @Test func undecidedRequestIsNotNotified() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let arm = sources[0]
        await arm.set(eligible: [Fixture.eligibility("e1")])
        await harness.refresh()
        let record = ActivationRecord(account: account, eligibleRoleId: "\(account.id.uuidString)|e1", roleName: "Owner",
                                      scopeName: "rg-app", source: .azureResource, action: .activate)
        record.status = .pendingApproval
        record.remoteRequestId = "req-e1"
        harness.context.insert(record)

        await arm.set(requestStatus: .success(.pendingApproval))
        await harness.refresh()
        #expect(record.status == .pendingApproval)
        #expect(harness.center.immediate.isEmpty)
    }

    /// One account failing leaves the other's rows and errors alone.
    @Test func accountsAreIsolated() async throws {
        let harness = try Harness()
        let (first, firstSources) = harness.addAccount(objectId: "oid-a", tenantId: "tenant-a", sortOrder: 0)
        let (second, secondSources) = harness.addAccount(objectId: "oid-b", tenantId: "tenant-b", sortOrder: 1)
        let roleA = Fixture.eligibility("a1"), roleB = Fixture.eligibility("b1")
        await firstSources[0].set(eligible: [roleA], assignments: [Fixture.activation(roleA, instance: "ia")])
        await secondSources[0].set(eligible: [roleB])
        await harness.refresh()

        await firstSources[0].fail(with: URLError(.notConnectedToInternet))
        await secondSources[0].set(eligible: [roleB], assignments: [Fixture.activation(roleB, instance: "ib")])
        await harness.refresh()
        #expect(harness.store.refreshErrors[first.id] == [.azureResource: .offline])
        #expect(harness.store.refreshErrors[second.id] == [:])
        #expect(first.activeAssignments.map(\.id) == ["\(first.id.uuidString)|ia"])   // kept from the last good refresh
        #expect(second.activeAssignments.map(\.id) == ["\(second.id.uuidString)|ib"])

        // A failed request on one account's row leaves the other account's rows without error.
        await firstSources[0].set(activate: [.failure(PIMError.http(status: 403, code: nil, message: "No"))], for: "a1")
        let input = ActivationInput(duration: "PT1H", justification: "Investigate")
        if let role = harness.role(first, "a1") {
            await harness.store.activate(role, input: input, refreshAfter: false)
        }
        #expect(harness.store.rowErrors.keys.sorted() == ["\(first.id.uuidString)|a1"])
    }

    @Test func expiryReminderIsScheduledThenRemoved() async throws {
        let harness = try Harness()
        let (account, sources) = harness.addAccount()
        let role = Fixture.eligibility("e1")
        await sources[0].set(eligible: [role], assignments: [Fixture.activation(role, instance: "i1",
                                                                                 end: .now.addingTimeInterval(3600))])
        await harness.refresh()
        let reminder = try #require(harness.center.pending.first)
        #expect(harness.center.pending.count == 1)
        #expect(reminder.id == "expiry-\(account.id.uuidString)|e1")
        #expect(reminder.roleId == "\(account.id.uuidString)|e1")
        #expect(reminder.category == NotificationScheduler.category)
        // Default lead time: 15 minutes before the end.
        #expect(abs((reminder.delay ?? 0) - 45 * 60) < 30)

        await sources[0].set(assignments: [])
        await harness.refresh()
        #expect(harness.center.pending.isEmpty)
    }

    /// A Microsoft sign-in hides the Azure CLI account of the same identity only for the sources it has loaded.
    @Test func microsoftSignInSupersedesOnlyLoadedSources() async throws {
        let harness = try Harness()
        let (msal, msalSources) = harness.addAccount(.msal, sortOrder: 0, sources: [.azureResource, .entraRole])
        let (cli, cliSources) = harness.addAccount(.azureCLI, sortOrder: 1)
        let role = Fixture.eligibility("e1")
        await cliSources[0].set(eligible: [role], assignments: [Fixture.activation(role, instance: "i1")])
        await msalSources[0].set(eligible: [role], assignments: [Fixture.activation(role, instance: "i1")])
        await msalSources[0].fail(with: URLError(.notConnectedToInternet))
        await harness.refresh()
        // Azure roles failed under the Microsoft sign-in: the CLI account still shows them.
        #expect(!harness.store.supersession().hides(cli.id, .azureResource))
        #expect(harness.store.activeActivations().map { $0.account?.id } == [cli.id])

        await msalSources[0].fail(with: nil)
        await harness.refresh()
        #expect(harness.store.supersession().isRetired(cli.id))
        #expect(cli.activeAssignments.isEmpty)
        #expect(!cli.eligibleRoles.isEmpty)   // kept, hidden: favorites made on it still resolve
        #expect(harness.store.activeActivations().map { $0.account?.id } == [msal.id])
    }
}

/// The Graph authentication-context step-up through the store's real token and source wiring.
@MainActor
struct StepUpTests {
    static let claims = #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#

    static var acrsRefusal: FakeTransport.Answer {
        let encoded = claims.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let message = "The authentication context requirement is not met. "
            + "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x&claims=\(encoded)"
        return .init(status: 400, json: ["error": ["code": "RoleAssignmentRequestAcrsValidationFailed", "message": message]])
    }

    struct Run {
        let status: RequestStatus?
        let claims: [String?]
        let harness: Harness
        let roleId: String
    }

    /// Activates an Entra role through real Graph clients on `transport`; returns the status and the claims asked.
    func activateEntraRole(_ transport: FakeTransport) async throws -> Run {
        let harness = try Harness()
        let (account, _) = harness.addAccount(.msal)
        let tokens = FakeTokenProvider(mode: .msal, objectId: account.objectId, tenantId: account.tenantId)
        harness.store.tokenProvider = { _ in tokens }
        harness.store.makeSources = { _, token, directory in
            PIMService.sources(token: token, directory: directory, transport: transport)
        }
        let role = EligibleRole(id: "g1", account: account, source: .entraRole, roleDefinitionId: "rd-g1",
                                roleName: "Global Reader", scope: "/", scopeName: "Directory", scopeType: "directory")
        harness.context.insert(role)
        let status = await harness.store.activate(role, input: ActivationInput(duration: "PT1H", justification: "Audit"),
                                                  refreshAfter: false)
        return Run(status: status, claims: tokens.claims, harness: harness, roleId: role.id)
    }

    @Test func stepsUpOnceThenSucceeds() async throws {
        let transport = FakeTransport(posts: [Self.acrsRefusal,
                                              .init(status: 201, json: ["id": "req-1", "status": "Provisioned"])])
        let run = try await activateEntraRole(transport)
        #expect(run.status == .provisioned)
        #expect(run.claims == [nil, Self.claims])
        #expect(transport.postURLs.count == 2)
    }

    /// A second refusal after the step-up is an error, not another sign-in.
    @Test func stepsUpOnlyOnce() async throws {
        let transport = FakeTransport(posts: [Self.acrsRefusal, Self.acrsRefusal, Self.acrsRefusal])
        let run = try await activateEntraRole(transport)
        #expect(run.status == nil)
        #expect(run.claims == [nil, Self.claims])
        #expect(transport.postURLs.count == 2)
        #expect(run.harness.store.rowErrors[run.roleId] != nil)
        #expect(run.harness.records().map(\.status) == [.failed])
    }
}
