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

    private func pending(_ item: FavoriteItem, _ policy: RolePolicy, last: String? = nil,
                         tenant: String = "T1") -> FavoriteRun.Pending {
        FavoriteRun.Pending(item: item, policy: policy, lastJustification: last, tenantId: tenant)
    }

    @Test func needsATicketOrAMissingJustification() {
        #expect(FavoriteRun.needs([pending(item, open)]) == FavoriteNeeds())
        #expect(!FavoriteRun.needs([pending(item, open)]).any)
        #expect(FavoriteRun.needs([pending(item, ticket, last: "x")])
                == FavoriteNeeds(ticketTenants: ["t1"], replacesJustification: true))
        let required = RolePolicy(requiresJustification: true)
        #expect(FavoriteRun.needs([pending(item, required)]) == FavoriteNeeds(justification: true))
        // A justification of the item or a last one is enough, and a typed one would replace it.
        #expect(FavoriteRun.needs([pending(item, required, last: "deploy")]) == FavoriteNeeds(replacesJustification: true))
        let own = FavoriteItem(eligibleRoleId: "r", justification: "mine")
        #expect(!FavoriteRun.needs([pending(own, required)]).any)
    }

    /// One ticket per tenant, in the favorite's order, never twice.
    @Test func ticketTenantsAreDistinct() {
        let needs = FavoriteRun.needs([pending(item, ticket, tenant: "B"), pending(item, ticket, tenant: "A"),
                                       pending(item, ticket, tenant: "b"), pending(item, open, tenant: "C")])
        #expect(needs.ticketTenants == ["b", "a"])
    }

    /// The ticket of the role's tenant goes to the roles that require one; a typed justification to every role.
    @Test func answersReachEveryRole() throws {
        let answers = FavoriteAnswers(justification: " Incident 42 ",
                                      tickets: ["t1": .init(system: " ServiceNow ", number: " INC42 ")])
        let withTicket = try FavoriteRun.input(for: item, policy: ticket, lastJustification: "old", answers: answers,
                                               tenantId: "T1").get()
        #expect(withTicket == ActivationInput(duration: "PT2H", justification: "Incident 42", ticketNumber: "INC42",
                                              ticketSystem: "ServiceNow"))
        let without = try FavoriteRun.input(for: item, policy: open, lastJustification: "old", answers: answers,
                                            tenantId: "T1").get()
        #expect(without == ActivationInput(duration: "PT2H", justification: "Incident 42"))
        // No typed justification: each role keeps its own.
        let blank = FavoriteAnswers(tickets: ["t1": .init(system: "Jira", number: "J-1")])
        #expect(try FavoriteRun.input(for: item, policy: ticket, lastJustification: "old", answers: blank,
                                      tenantId: "T1").get().justification == "old")
    }

    /// A ticket of one tenant never goes to a role of another.
    @Test func ticketsStayInTheirTenant() {
        let answers = FavoriteAnswers(tickets: ["t1": .init(system: "Jira", number: "J-1")])
        #expect(FavoriteRun.input(for: item, policy: ticket, lastJustification: "x", answers: answers, tenantId: "T2")
                == .failure(.empty("ticket")))
    }

    /// Without answers (a link, Shortcuts) or with an incomplete ticket, a ticket role is not sent.
    @Test func noTicketNoRequest() {
        #expect(FavoriteRun.input(for: item, policy: ticket, lastJustification: "x") == .failure(.empty("ticket")))
        let noSystem = FavoriteAnswers(justification: "j", tickets: ["t1": .init(number: "INC1")])
        #expect(FavoriteRun.input(for: item, policy: ticket, lastJustification: "x", answers: noSystem, tenantId: "T1")
                == .failure(.empty("ticket")))
    }

    @Test func blockFollowsTheNeeds() {
        let needs = FavoriteNeeds(justification: true, ticketTenants: ["a", "b"])
        let both: [String: FavoriteAnswers.Ticket] = ["a": .init(system: "Jira", number: "1"), "b": .init(system: "SN", number: "2")]
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers()) == .justificationRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j")) == .ticketSystemRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j", tickets: ["a": .init(system: "Jira")]))
                == .ticketRequired)
        // The second tenant is checked too.
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j", tickets: ["a": both["a"]!]))
                == .ticketSystemRequired)
        #expect(FavoriteRun.block(needs, answers: FavoriteAnswers(justification: "j", tickets: both)) == nil)
        #expect(FavoriteRun.block(FavoriteNeeds(ticketTenants: ["a"]), answers: FavoriteAnswers(tickets: both)) == nil)
    }
}
