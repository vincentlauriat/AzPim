import Foundation
import Testing
@testable import AzPimCore

/// Least-privilege defaults: remembered duration or 1 h, 15-minute steps, policy cap, and why Activate is disabled.
struct ActivationDurationTests {
    @Test func defaultsToOneHourWithoutAMemory() {
        #expect(ActivationDuration.defaultMinutes(lastUsed: nil, policyMax: "PT8H") == 60)
        #expect(ActivationDuration.defaultMinutes(lastUsed: nil, policyMax: nil) == 60)
    }

    @Test func policyShorterThanAnHourDefaultsToItsMaximum() {
        #expect(ActivationDuration.defaultMinutes(lastUsed: nil, policyMax: "PT30M") == 30)
        #expect(ActivationDuration.defaultMinutes(lastUsed: nil, policyMax: "PT10M") == 10)
    }

    @Test func remembersTheLastDurationWithinThePolicy() {
        #expect(ActivationDuration.defaultMinutes(lastUsed: "PT2H15M", policyMax: "PT8H") == 135)
        // The policy got shorter since: capped.
        #expect(ActivationDuration.defaultMinutes(lastUsed: "PT8H", policyMax: "PT4H") == 240)
        // Unreadable memory: 1 h.
        #expect(ActivationDuration.defaultMinutes(lastUsed: "garbage", policyMax: "PT8H") == 60)
    }

    @Test func stepsOnTheQuarterHourGrid() {
        #expect(ActivationDuration.step(60, upward: true, policyMax: "PT8H") == 75)
        #expect(ActivationDuration.step(60, upward: false, policyMax: "PT8H") == 45)
        // Off the grid: snaps to the next mark either way.
        #expect(ActivationDuration.step(50, upward: true, policyMax: "PT8H") == 60)
        #expect(ActivationDuration.step(50, upward: false, policyMax: "PT8H") == 45)
    }

    @Test func stepsStayWithinOneStepAndThePolicyMaximum() {
        #expect(ActivationDuration.step(15, upward: false, policyMax: "PT8H") == 15)
        #expect(ActivationDuration.step(480, upward: true, policyMax: "PT8H") == 480)
        // A maximum off the grid is reachable, and stepping down from it lands on the grid.
        #expect(ActivationDuration.step(75, upward: true, policyMax: "PT1H20M") == 80)
        #expect(ActivationDuration.step(80, upward: false, policyMax: "PT1H20M") == 75)
        // A maximum under one step is both ends.
        #expect(ActivationDuration.step(10, upward: false, policyMax: "PT10M") == 10)
        #expect(ActivationDuration.step(10, upward: true, policyMax: "PT10M") == 10)
    }

    @Test func unknownPolicyCapsAtEightHours() {
        #expect(ActivationDuration.maxMinutes(policyMax: nil) == 480)
        #expect(ActivationDuration.maxMinutes(policyMax: "PT24H") == 1440)
        #expect(ActivationDuration.iso(135) == "PT2H15M")
    }

    private func id(_ tenant: String, _ oid: String, _ upn: String) -> String {
        AccountSupersede.identity(tenantId: tenant, objectId: oid, upn: upn)
    }

    /// Stable across the Azure CLI → Microsoft sign-in supersede and refreshes: no account, no row id, no case.
    @Test func roleKeyIgnoresAccountAndCase() {
        let cli = ActivationDuration.roleKey(identity: id("TENANT-CONTOSO", "OID-1", "V.Admin@Contoso.com"),
                                             source: .azureResource, roleDefinitionId: "/Providers/RoleDefinitions/Contrib",
                                             roleName: "Contributor", scope: "/subs/S1/rg/app-prod")
        let msal = ActivationDuration.roleKey(identity: id(" tenant-contoso", "oid-1", "v.admin@contoso.com"),
                                              source: .azureResource, roleDefinitionId: "/providers/roledefinitions/contrib",
                                              roleName: "Contributor", scope: "/subs/s1/rg/app-prod")
        #expect(cli != nil)
        #expect(cli == msal)
    }

    @Test func roleKeyTellsRolesApart() {
        func key(tenant: String = "t", person: String = "oid", source: RoleSource = .azureResource,
                 definition: String? = "d", name: String = "Reader", scope: String = "/s") -> String? {
            ActivationDuration.roleKey(identity: id(tenant, person, "u@x"), source: source,
                                       roleDefinitionId: definition, roleName: name, scope: scope)
        }
        let base = key()
        #expect(base != key(tenant: "other"))
        #expect(base != key(person: "someone-else"))
        #expect(base != key(source: .entraRole))
        #expect(base != key(definition: "e"))
        #expect(base != key(scope: "/s2"))
        // Without a definition id the name counts; a placeholder name matches nothing.
        #expect(key(definition: nil) != key(definition: nil, name: "Owner"))
        #expect(key(definition: nil, name: RoleMerge.fallbackARMName) == nil)
    }
}

struct ActivationBlockTests {
    private func facts(minutes: Int = 60, justification: String = "Deploy", requiresTicket: Bool = false,
                       ticket: String = "") -> ActivationBlock.Facts {
        ActivationBlock.Facts(minutes: minutes, policyMax: "PT8H", requiresJustification: true,
                              justification: justification, requiresTicket: requiresTicket, ticket: ticket)
    }

    @Test func readyWhenEverythingIsThere() {
        #expect(ActivationBlock.reason(facts()) == nil)
        #expect(ActivationBlock.reason(facts(requiresTicket: true, ticket: "CHG-1")) == nil)
        var optional = facts(justification: "")
        optional.requiresJustification = false
        #expect(ActivationBlock.reason(optional) == nil)
    }

    @Test func eachMissingPieceHasItsReason() {
        #expect(ActivationBlock.reason(facts(justification: "  ")) == .justificationRequired)
        #expect(ActivationBlock.reason(facts(justification: String(repeating: "x", count: 501))) == .justificationTooLong)
        #expect(ActivationBlock.reason(facts(requiresTicket: true)) == .ticketRequired)
        #expect(ActivationBlock.reason(facts(requiresTicket: true, ticket: String(repeating: "1", count: 101)))
                == .ticketTooLong)
        #expect(ActivationBlock.reason(facts(minutes: 540)) == .durationTooLong(maxMinutes: 480))
        #expect(ActivationBlock.reason(facts(minutes: 3)) == .durationTooShort)
    }

    @Test func stateComesBeforeTheForm() {
        var all = facts(minutes: 540, justification: "", requiresTicket: true)
        all.offline = true
        #expect(ActivationBlock.reason(all) == .offline)
        all.pending = true
        #expect(ActivationBlock.reason(all) == .pending)
        all.inProgress = true
        #expect(ActivationBlock.reason(all) == .inProgress)
        // The duration is checked before the justification and the ticket.
        #expect(ActivationBlock.reason(facts(minutes: 540, justification: "", requiresTicket: true))
                == .durationTooLong(maxMinutes: 480))
    }

    @Test func messagesAreShort() {
        let all: [ActivationBlock] = [.inProgress, .pending, .offline, .durationTooLong(maxMinutes: 90), .durationTooShort,
                                      .justificationRequired, .justificationTooLong, .ticketRequired, .ticketTooLong]
        // One sentence each; the pending one also says how to send another.
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "fr_FR")] {
            for block in all where block != .pending {
                #expect(block.message(locale: locale).hasSuffix("."))
                #expect(block.message(locale: locale).dropLast().contains(".") == false)
            }
        }
        let english = Locale(identifier: "en_US")
        #expect(ActivationBlock.pending.message(locale: english).hasSuffix("Cancel it in History to send another."))
        #expect(plain(ActivationBlock.durationTooLong(maxMinutes: 90).message(locale: english))
                == "The policy allows 1 hr 30 min at most.")
    }
}
