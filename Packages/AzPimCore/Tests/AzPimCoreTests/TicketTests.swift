import Foundation
import Testing
@testable import AzPimCore

struct TicketRecallTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ number: String, hoursAgo: Double) -> TicketRecall.Entry {
        TicketRecall.Entry(number: number, usedAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    /// Same incident: offered again under 8 h, never at or after 8 h, never from a date in the future.
    @Test func prefillsOnlyWithinEightHours() {
        #expect(TicketRecall.prefill([entry("INC1", hoursAgo: 7 + 59 / 60)], now: now) == "INC1")
        #expect(TicketRecall.prefill([entry("INC1", hoursAgo: 8)], now: now) == "")
        #expect(TicketRecall.prefill([entry("INC1", hoursAgo: 8 + 1 / 60)], now: now) == "")
        #expect(TicketRecall.prefill([entry("INC1", hoursAgo: -1)], now: now) == "")
        #expect(TicketRecall.prefill([nil], now: now) == "")
        #expect(TicketRecall.prefill([], now: now) == "")
    }

    /// Grouped sheet: the most recent number still within the window, whichever role used it.
    @Test func prefillPicksTheMostRecent() {
        let entries = [entry("OLD", hoursAgo: 9), entry("INC2", hoursAgo: 3), nil, entry("INC3", hoursAgo: 1)]
        #expect(TicketRecall.prefill(entries, now: now) == "INC3")
    }

    @Test func pruneKeepsCachedRecentRoles() {
        let entries = ["a": entry("1", hoursAgo: 1), "b": entry("2", hoursAgo: 1), "c": entry("3", hoursAgo: 9)]
        #expect(TicketRecall.pruned(entries, keeping: ["a", "c"], now: now) == ["a": entry("1", hoursAgo: 1)])
    }

    @Test func roundTripsThroughThePreferencesForm() {
        let entries = ["role": entry("INC1", hoursAgo: 2)]
        let stored: [String: Any] = TicketRecall.encode(entries)
        #expect(TicketRecall.decode(stored) == entries)
        // Another shape is ignored, never trusted.
        #expect(TicketRecall.decode(["role": "INC1", "x": ["number": 3]]).isEmpty)
        #expect(TicketRecall.decode(nil).isEmpty)
        #expect(TicketRecall.tenantKey("ABC-def") == "abc-def")
    }

    @Test func ticketInfoSendsBothFieldsTrimmed() {
        let input = ActivationInput(duration: "PT1H", justification: "j", ticketNumber: " INC1 ", ticketSystem: " ServiceNow ")
        #expect(input.ticketInfo == ["ticketNumber": "INC1", "ticketSystem": "ServiceNow"])
        // No made-up system; no ticket at all without a number.
        #expect(ActivationInput(duration: "PT1H", justification: "j", ticketNumber: "INC1").ticketInfo == ["ticketNumber": "INC1"])
        #expect(ActivationInput(duration: "PT1H", justification: "j", ticketNumber: "  ", ticketSystem: "Jira").ticketInfo == nil)
    }

    @Test func ticketSystemValidation() {
        #expect(Validation.ticketSystem("", required: true) == .empty("ticketSystem"))
        #expect(Validation.ticketSystem("", required: false) == nil)
        #expect(Validation.ticketSystem(String(repeating: "s", count: 101), required: false) == .tooLong("ticketSystem", max: 100))
        #expect(Validation.ticketSystem("Jira", required: true) == nil)
    }
}

struct FavoriteAnswersTests {
    let ticket = RolePolicy(maxDuration: "PT8H", requiresJustification: true, requiresTicket: true)
    let open = RolePolicy(maxDuration: "PT8H", requiresJustification: false)
    let item = FavoriteItem(eligibleRoleId: "r", duration: "PT2H")

    @Test func needsATicketOrAMissingJustification() {
        #expect(FavoriteRun.needs([.init(item: item, policy: open, lastJustification: nil)]) == FavoriteNeeds())
        #expect(!FavoriteRun.needs([.init(item: item, policy: open, lastJustification: nil)]).any)
        #expect(FavoriteRun.needs([.init(item: item, policy: ticket, lastJustification: "x")]) == FavoriteNeeds(ticket: true))
        let required = RolePolicy(requiresJustification: true)
        #expect(FavoriteRun.needs([.init(item: item, policy: required, lastJustification: nil)])
                == FavoriteNeeds(justification: true))
        // A justification of the item or a last one is enough.
        #expect(!FavoriteRun.needs([.init(item: item, policy: required, lastJustification: "deploy")]).any)
        let own = FavoriteItem(eligibleRoleId: "r", justification: "mine")
        #expect(!FavoriteRun.needs([.init(item: own, policy: required, lastJustification: nil)]).any)
    }

    /// The ticket goes to the roles that require one; a typed justification to every role.
    @Test func answersReachEveryRole() throws {
        let answers = FavoriteAnswers(justification: " Incident 42 ", ticketSystem: " ServiceNow ", ticketNumber: " INC42 ")
        let withTicket = try FavoriteRun.input(for: item, policy: ticket, lastJustification: "old", answers: answers).get()
        #expect(withTicket == ActivationInput(duration: "PT2H", justification: "Incident 42", ticketNumber: "INC42",
                                              ticketSystem: "ServiceNow"))
        let without = try FavoriteRun.input(for: item, policy: open, lastJustification: "old", answers: answers).get()
        #expect(without == ActivationInput(duration: "PT2H", justification: "Incident 42"))
        // No typed justification: each role keeps its own.
        let blank = FavoriteAnswers(ticketSystem: "Jira", ticketNumber: "J-1")
        #expect(try FavoriteRun.input(for: item, policy: ticket, lastJustification: "old", answers: blank).get().justification
                == "old")
    }

    /// Without answers (a link, Shortcuts) or with an incomplete ticket, a ticket role is not sent.
    @Test func noTicketNoRequest() {
        #expect(FavoriteRun.input(for: item, policy: ticket, lastJustification: "x") == .failure(.empty("ticket")))
        let noSystem = FavoriteAnswers(justification: "j", ticketNumber: "INC1")
        #expect(FavoriteRun.input(for: item, policy: ticket, lastJustification: "x", answers: noSystem) == .failure(.empty("ticket")))
    }

    @Test func blockFollowsTheNeeds() {
        let needs = FavoriteNeeds(justification: true, ticket: true)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers()) == .justificationRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j")) == .ticketSystemRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j", ticketSystem: "Jira")) == .ticketRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j", ticketSystem: "Jira", ticketNumber: "1"))
                == nil)
        #expect(FavoriteRun.block(FavoriteNeeds(ticket: true), answers: FavoriteAnswers(ticketSystem: "Jira", ticketNumber: "1"))
                == nil)
    }
}
