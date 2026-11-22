import Testing
@testable import AzPimCore

struct RoleSearchTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(RoleSearch.matches("", fields: ["Reader"]))
        #expect(RoleSearch.matches("   ", fields: []))
        #expect(RoleSearch.isEmpty(" \t"))
        #expect(!RoleSearch.isEmpty(" r"))
    }

    @Test(arguments: ["license", "LICENSE", "lîcensé", "  License  "])
    func ignoresCaseAccentsAndSpaces(query: String) {
        #expect(RoleSearch.matches(query, fields: ["License Administrator", "Directory"]))
    }

    @Test func accentsInTheFieldAreIgnoredToo() {
        #expect(RoleSearch.matches("societe", fields: ["Lecteur", "Société Générale"]))
    }

    @Test func everyWordMustMatchSomeField() {
        let fields = ["Contributor", "rg-app-prod-weu001", "Azure roles"]
        #expect(RoleSearch.matches("contrib prod", fields: fields))
        #expect(RoleSearch.matches("azure contrib", fields: fields))
        #expect(!RoleSearch.matches("contrib dev", fields: fields))
    }

    @Test func noMatch() {
        #expect(!RoleSearch.matches("owner", fields: ["Reader", "Tenant Root Group"]))
    }
}

struct HeroSummaryTests {
    @Test func allSegments() {
        let summary = HeroSummary(activeCount: 2, nextExpiry: "42m", pendingCount: 1)
        #expect(summary.line == "2 active · next expiry in 42m · 1 pending")
    }

    @Test func leavesOutWhatDoesNotApply() {
        #expect(HeroSummary(activeCount: 0, nextExpiry: nil, pendingCount: 0).line == "0 active")
        #expect(HeroSummary(activeCount: 0, nextExpiry: nil, pendingCount: 3).line == "0 active · 3 pending")
        #expect(HeroSummary(activeCount: 1, nextExpiry: "3:12", pendingCount: 0).line == "1 active · next expiry in 3:12")
    }
}

struct MenuBarBadgeTests {
    @Test func keyFollowsTheActiveCount() {
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 0).keySymbol == "key.fill")
        #expect(MenuBarBadge(activeCount: 2, pendingCount: 0).keySymbol == "key.horizontal.fill")
    }

    @Test func hourglassOnlyWhileARequestWaits() {
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 0).pendingSymbol == nil)
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 0).spokenPending == nil)
        #expect(MenuBarBadge(activeCount: 1, pendingCount: 1).pendingSymbol == "hourglass")
        #expect(MenuBarBadge(activeCount: 1, pendingCount: 1).spokenPending == "1 request waiting for approval")
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 2).spokenPending == "2 requests waiting for approval")
    }
}

struct RequestDecisionTests {
    @Test func approved() {
        let text = RequestDecision.notification(status: .provisioned, roleName: "Reader", scopeName: "Tenant Root Group")
        #expect(text?.title == "Request approved: Reader")
        #expect(text?.body == "Tenant Root Group — the role is active.")
    }

    @Test(arguments: [(RequestStatus.denied, "Request denied: Owner"), (.failed, "Request expired or failed: Owner"),
                      (.canceled, "Request canceled: Owner")])
    func refused(status: RequestStatus, title: String) {
        #expect(RequestDecision.notification(status: status, roleName: "Owner", scopeName: "rg")?.title == title)
    }

    @Test(arguments: [RequestStatus.sent, .pendingApproval])
    func notADecision(status: RequestStatus) {
        #expect(RequestDecision.notification(status: status, roleName: "Owner", scopeName: "rg") == nil)
    }
}
