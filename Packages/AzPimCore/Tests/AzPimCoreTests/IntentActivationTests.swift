import Foundation
import Testing
@testable import AzPimCore

/// Shortcuts activation: never a request the policy refuses, missing fields asked, the setting obeyed.
struct IntentActivationTests {
    private let open = RolePolicy(maxDuration: "PT8H", requiresJustification: false)
    private let strict = RolePolicy(maxDuration: "PT2H", requiresJustification: true, requiresTicket: true)

    @Test func sendsTheDefaultDurationWhenNothingIsRequired() {
        let decision = IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true))
        #expect(decision == .send(ActivationInput(duration: "PT1H", justification: "")))
    }

    @Test func theSettingRefusesFirst() {
        let decision = IntentActivation.decide(.init(allowed: false, policy: open, policyKnown: true, active: true))
        #expect(decision == .refused(.disabled))
    }

    @Test func anUnknownPolicyIsRefused() {
        #expect(IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: false)) == .refused(.unknownPolicy))
    }

    @Test func activeAndBlockedStatesSendNothing() {
        #expect(IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true, active: true))
                == .refused(.alreadyActive))
        #expect(IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true, pending: true))
                == .refused(.blocked(.pending)))
        #expect(IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true, offline: true))
                == .refused(.blocked(.offline)))
    }

    /// Missing fields are asked one at a time; a blank answer counts as missing.
    @Test func missingFieldsAreAsked() {
        #expect(IntentActivation.decide(.init(allowed: true, policy: strict, policyKnown: true, justification: "  "))
                == .needsJustification)
        #expect(IntentActivation.decide(.init(allowed: true, policy: strict, policyKnown: true, justification: "Audit"))
                == .needsTicketSystem)
        #expect(IntentActivation.decide(.init(allowed: true, policy: strict, policyKnown: true, justification: "Audit",
                                              ticketSystem: "Jira")) == .needsTicket)
        let ready = IntentActivation.decide(.init(allowed: true, policy: strict, policyKnown: true,
                                                  justification: " Audit ", ticketSystem: " Jira ", ticket: "INC-1"))
        #expect(ready == .send(ActivationInput(duration: "PT1H", justification: "Audit", ticketNumber: "INC-1",
                                               ticketSystem: "Jira")))
    }

    /// A ticket typed for a role that does not require one is not sent (as in the Activation Sheet).
    @Test func aTicketIsSentOnlyWhenRequired() {
        let decision = IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true,
                                                     ticketSystem: "Jira", ticket: "INC-1"))
        #expect(decision == .send(ActivationInput(duration: "PT1H", justification: "")))
    }

    @Test func theDurationAskedIsCappedByThePolicy() {
        let decision = IntentActivation.decide(.init(allowed: true, policy: strict, policyKnown: true, requestedMinutes: 600,
                                                     justification: "Audit", ticketSystem: "Jira", ticket: "INC-1"))
        #expect(decision == .send(ActivationInput(duration: "PT2H", justification: "Audit", ticketNumber: "INC-1",
                                                  ticketSystem: "Jira")))
        #expect(IntentActivation.minutes(.init(allowed: true, policy: open, policyKnown: true, lastDuration: "PT45M")) == 45)
    }

    @Test func aTooLongJustificationIsRefused() {
        let decision = IntentActivation.decide(.init(allowed: true, policy: open, policyKnown: true,
                                                     justification: String(repeating: "a", count: 501)))
        #expect(decision == .refused(.blocked(.justificationTooLong)))
    }

    @Test func summariesInFrench() {
        let french = Locale(identifier: "fr_FR")
        let text = IntentSummary.deactivated([.init(name: "Owner"), .init(name: "Reader", error: "refusé")], locale: french)
        #expect(text == "Désactivés\u{a0}: 1 sur 2 — Reader: refusé")
        let now = Date(timeIntervalSince1970: 0)
        let line = IntentSummary.activeLine(name: "Contributor", scope: "Prod", endAt: now.addingTimeInterval(42 * 60),
                                            now: now, locale: french)
        #expect(line.hasPrefix("Contributor — Prod, reste 42"))
        #expect(IntentSummary.activeLine(name: "A", scope: "B", endAt: nil, locale: Locale(identifier: "en_US"))
                == "A — B, no end date")
    }
}
