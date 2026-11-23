@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import Testing

/// Links, Extend, favorites run from the UI and the remembered duration: each sends only what was shown or meant.
@MainActor
struct ReviewFixTests {
    let harness: Harness
    let account: Account
    let arm: FakeSource
    let owner = Fixture.eligibility("e1", role: "Owner")
    let reader = Fixture.eligibility("e2", role: "Reader")

    init() async throws {
        harness = try Harness()
        let (account, sources) = harness.addAccount()
        self.account = account
        arm = sources[0]
        await arm.set(eligible: [owner, reader])
    }

    private func id(_ remote: String, of account: Account? = nil) -> String {
        "\((account ?? self.account).id.uuidString)|\(remote)"
    }

    private func favorite(_ remotes: [String], justification: String? = "Deploy") -> Favorite {
        let favorite = Favorite(name: "Morning", items: remotes.map {
            FavoriteItem(eligibleRoleId: id($0), duration: "PT1H", justification: justification)
        })
        harness.context.insert(favorite)
        return favorite
    }

    /// A provisioned request of this role, sent `ago` seconds ago.
    private func record(_ remote: String, justification: String, duration: String = "PT2H", ago: TimeInterval,
                        action: ActivationAction = .activate, status: RequestStatus = .provisioned) {
        let record = ActivationRecord(account: account, eligibleRoleId: id(remote), roleName: "Owner", scopeName: "Scope",
                                      source: .azureResource, action: action, requestedDuration: duration,
                                      justification: justification)
        record.status = status
        record.sentAt = .now.addingTimeInterval(-ago)
        harness.context.insert(record)
    }

    // MARK: - azpim://activate

    /// A role active when the confirmation was built is listed as already active, and is not sent even if it
    /// ended while the dialog was open. An unknown role and a ticket role are listed as not sent.
    @Test func aLinkSendsOnlyWhatItsConfirmationListed() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        let favorite = favorite(["e1", "gone"])
        var shown = ""
        let harness = harness, arm = arm
        let outcome = await harness.store.linkRunFavorite(favorite) { text in
            shown = text
            await arm.set(assignments: [])   // the activation ends while the dialog is open
            await harness.refresh()
            return true
        }
        #expect(shown.contains("already active"))
        #expect(shown.contains("Unknown role"))
        #expect(outcome != nil)
        #expect(await arm.activateCount == 0)
    }

    @Test func aDeclinedLinkSendsNothing() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await harness.refresh()
        let outcome = await harness.store.linkRunFavorite(favorite(["e1"])) { _ in false }
        #expect(outcome == nil)
        #expect(await arm.activateCount == 0)
    }

    @Test func aLinkNeverSendsATicketRole() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false, requiresTicket: true)))
        await harness.refresh()
        var shown = ""
        _ = await harness.store.linkRunFavorite(favorite(["e1"])) { shown = $0; return true }
        #expect(shown.contains("not sent"))
        #expect(await arm.activateCount == 0)
    }

    // MARK: - Extend

    /// The justification of the request that made the activation, never the older one remembered for the role.
    @Test func extendSendsTheJustificationOfTheActivationItExtends() async throws {
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        harness.role(account, "e1")?.lastJustification = "Old"
        record("e1", justification: "New", duration: "PT2H", ago: 3600)
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasPrefix("Extended until"))
        #expect(await arm.inputs.last == ActivationInput(duration: "PT2H", justification: "New"))
    }

    /// The last request of AzPim predates the activation (made elsewhere since): its justification is not reused.
    @Test func extendRefusesAJustificationOlderThanTheActivation() async throws {
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1", start: .now.addingTimeInterval(-3600))])
        await harness.refresh()
        harness.role(account, "e1")?.lastJustification = "Last week"
        record("e1", justification: "Last week", ago: 7 * 86_400)
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasSuffix("The role is still active."))
        #expect(await arm.deactivateCount == 0)
        #expect(await arm.activateCount == 0)
    }

    /// A policy that asks for no justification: none is sent.
    @Test func extendSendsNoJustificationWhenNotRequired() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        harness.role(account, "e1")?.lastJustification = "Release"
        record("e1", justification: "Release", ago: 3600)
        _ = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(await arm.inputs.last?.justification == "")
    }

    /// An id of the Azure CLI account a Microsoft sign-in superseded (an older notification) extends the same role.
    @Test func extendResolvesASupersededRole() async throws {
        await arm.set(eligible: [owner])
        await harness.refresh()
        let (msal, msalSources) = harness.addAccount(.msal, sortOrder: 1)
        let msalArm = msalSources[0]
        await msalArm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await msalArm.set(eligible: [owner], assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        #expect(harness.store.supersession().hides(account.id, .azureResource))
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasPrefix("Extended until"))
        #expect(await msalArm.activateCount == 1)
        #expect(harness.store.activeActivations().map(\.id) == ["\(msal.id.uuidString)|e1-new-1"])
    }

    /// The follow-up notification never carries Azure's error; the panel text keeps it.
    @Test func theExtendNotificationIsGeneric() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        await arm.set(deactivate: .failure(PIMError.http(status: 500, code: nil, message: "Boom")))
        let body = await harness.store.extendFromNotification(eligibleRoleId: id("e1"))
        #expect(!body.contains("Boom"))
        #expect(body.contains("still active"))
        #expect(harness.store.rowErrors.values.contains { $0.contains("Boom") })

        await arm.set(deactivate: .success(RequestOutcome(requestId: "d", status: .provisioned)))
        await arm.set(activate: Array(repeating: .failure(PIMError.http(status: 403, code: nil, message: "Nope")), count: 4),
                      for: "e1")
        let failed = await harness.store.extendFromNotification(eligibleRoleId: id("e1"))
        #expect(!failed.contains("Nope"))
        #expect(failed.hasPrefix("Role deactivated"))
    }

    // MARK: - Remembered duration

    /// Only the Activation Sheet's duration is remembered: never a Shortcuts duration.
    @Test func aShortcutsDurationIsNotRemembered() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await harness.refresh()
        let request = RoleStore.IntentRequest(roleId: id("e1"), minutes: 120, justification: nil, ticket: nil)
        _ = try await harness.store.intentActivate(request, allowed: true, ask: { _ in nil }, confirm: { _ in true })
        #expect(await arm.inputs.last?.duration == "PT2H")
        #expect(harness.store.defaultDurationMinutes(for: try #require(harness.role(account, "e1"))) == 60)
    }

    // MARK: - Favorites run from the panel and the Favorites window

    /// A role whose policy cannot be read is not sent on the policy's defaults.
    @Test func aUIRunNeverSendsOnAnUnreadablePolicy() async throws {
        await arm.set(policy: .failure(URLError(.timedOut)))
        await harness.refresh()
        let favorite = favorite(["e1"])
        let request = await harness.store.startFavorite(favorite, fromPanel: true)
        #expect(request == nil)
        #expect(await arm.activateCount == 0)
        #expect(harness.store.favoriteToast?.text.contains("unreadable policy") == true)
    }

    /// The grouped sheet sends only the roles it listed: one active when it opened is not sent once it ends.
    @Test func theGroupedSheetSendsOnlyItsRoles() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false, requiresTicket: true)))
        await arm.set(assignments: [Fixture.activation(reader, instance: "i2")])
        await harness.refresh()
        let favorite = favorite(["e1", "e2"])
        let request = try #require(await harness.store.startFavorite(favorite, fromPanel: true))
        #expect(request.roles.map(\.role.id) == [id("e1")])
        await arm.set(assignments: [])   // the Reader activation ends while the sheet is open
        await harness.refresh()
        let answers = FavoriteAnswers(justification: "", tickets: [TicketRecall.tenantKey("tenant-1"):
                                                                     FavoriteAnswers.Ticket(system: "Jira", number: "INC-1")])
        _ = await harness.store.runFavorite(request, answers: answers, fromPanel: true)
        #expect(await arm.activateCount == 1)
        #expect(harness.records().map(\.eligibleRoleId) == [id("e1")])
    }

    // MARK: - Second review

    /// Link and Shortcuts favorite runs read never-read policies in the background: no sign-in window can open
    /// before the confirmation.
    @Test func favoriteRunsReadPoliciesInTheBackground() async throws {
        await arm.set(policy: .failure(URLError(.timedOut)))
        await harness.refresh()   // never read
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        let favorite = favorite(["e1"])
        let before = await arm.policyReadsInBackground.count
        _ = await harness.store.linkRunFavorite(favorite) { _ in false }
        try #require(harness.role(account, "e1")).policyFetchedAt = nil
        _ = try? await harness.store.intentRunFavorite(.init(id: favorite.id), allowed: true, ask: { _ in nil },
                                                       confirm: { _ in false })
        let reads = await arm.policyReadsInBackground.dropFirst(before)
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0 })
        #expect(await arm.activateCount == 0)
    }

    /// A role the link's confirmation listed as sent is sent.
    @Test func aConfirmedLinkRoleIsSent() async throws {
        await arm.set(policy: .success(RolePolicy(maxDuration: "PT8H", requiresJustification: false)))
        await harness.refresh()
        let outcome = await harness.store.linkRunFavorite(favorite(["e1"])) { _ in true }
        #expect(outcome?.isFullSuccess == true)
        #expect(await arm.activateCount == 1)
        #expect(harness.records().map(\.eligibleRoleId) == [id("e1")])
        #expect(harness.records().map(\.viaFavorite) == ["Morning"])
    }

    /// A request of another role and a deactivation are never reused by Extend.
    @Test func extendIgnoresOtherRolesAndDeactivations() async throws {
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        record("e2", justification: "Other role", ago: 60)
        record("e1", justification: "Deactivation", ago: 30, action: .deactivate)
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasSuffix("The role is still active."))
        #expect(await arm.deactivateCount == 0)
        #expect(await arm.activateCount == 0)
    }

    /// A request sent up to 5 minutes before the activation started counts as the one that made it.
    @Test(arguments: [(240.0, true), (360.0, false)])
    func extendAllowsFiveMinutesOfClockSkew(before: TimeInterval, reused: Bool) async throws {
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1", start: .now.addingTimeInterval(-3600))])
        await harness.refresh()
        record("e1", justification: "Early", ago: 3600 + before)
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasPrefix("Extended until") == reused)
        #expect(await arm.inputs.last?.justification == (reused ? "Early" : nil))
    }

    /// The only request since the activation is not confirmed yet: refused with that reason, nothing ended.
    @Test func extendRefusesAnUnconfirmedActivation() async throws {
        await arm.set(assignments: [Fixture.activation(owner, instance: "i1")])
        await harness.refresh()
        record("e1", justification: "Pending", ago: 3600, status: .sent)
        let text = await harness.store.extend(eligibleRoleId: id("e1"))
        #expect(text.hasPrefix("This activation isn't confirmed yet."))
        #expect(await arm.deactivateCount == 0)
        #expect(await arm.activateCount == 0)
    }

    /// The Activation Sheet's request remembers its duration.
    @Test func theSheetRemembersTheDuration() async throws {
        await harness.refresh()
        let role = try #require(harness.role(account, "e1"))
        let input = ActivationInput(duration: "PT2H15M", justification: "D")
        #expect(await harness.store.activateFromSheet(role, input: input, fromPanel: true) == .provisioned)
        #expect(harness.store.defaultDurationMinutes(for: try #require(harness.role(account, "e1"))) == 135)
    }
}
