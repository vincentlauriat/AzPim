import Foundation
@testable import AzPimCore
import Testing

/// VoiceOver labels of the role rows and the spoken time left, in French and English. The duration words come from
/// the system formatter (its joiner may change between OS versions): checked by their parts.
struct SpokenRoleTests {
    @Test func spokenDurationIsInWordsAndRoundedToTheMinute() {
        let english3h15 = plain(SpokenDuration.text(3 * 3600 + 15 * 60 + 42, locale: english))
        #expect(english3h15.contains("3 hours") && english3h15.contains("15 minutes"))
        let french3h15 = plain(SpokenDuration.text(3 * 3600 + 15 * 60 + 42, locale: french))
        #expect(french3h15.contains("3 heures") && french3h15.contains("15 minutes"))
        #expect(plain(SpokenDuration.text(3600, locale: french)) == "1 heure")
        #expect(plain(SpokenDuration.text(61, locale: english)) == "1 minute")
        // Same text all through a minute: a focused countdown is not read again every second.
        #expect(SpokenDuration.text(4 * 60 + 1, locale: french) == SpokenDuration.text(4 * 60 + 59, locale: french))
        #expect(SpokenDuration.text(59, locale: french) == "moins d’une minute")
        #expect(SpokenDuration.text(-5, locale: english) == "less than a minute")
    }

    @Test func activeRowLabel() {
        let french = SpokenRole.label(role: "Contributor", source: .azureResource, scope: "rg-app-prod",
                                      state: .active(remaining: 3 * 3600 + 15 * 60), locale: french)
        #expect(plain(french).hasPrefix("Contributor, rôle Azure, rg-app-prod, actif, reste 3 heures"))
        #expect(plain(french).hasSuffix("15 minutes"))
        let english = SpokenRole.label(role: "Contributor", source: .azureResource, scope: "rg-app-prod",
                                       state: .active(remaining: 42 * 60), alsoPermanent: true, locale: english)
        #expect(plain(english) == "Contributor, Azure role, rg-app-prod, active, 42 minutes left, also permanent")
    }

    @Test func otherStates() {
        #expect(SpokenRole.label(role: "Global Reader", source: .entraRole, scope: "Annuaire", state: .eligible,
                                 locale: french) == "Global Reader, rôle Entra, Annuaire, éligible")
        #expect(SpokenRole.label(role: "Member", source: .pimGroup, scope: "Ops", state: .pendingApproval, viaGroup: true,
                                 account: "Contoso", locale: english)
                == "Member, PIM group, Ops, via group, Contoso, pending approval")
        #expect(SpokenRole.label(role: "Reader", source: .azureResource, scope: nil, state: .sent, locale: french)
                == "Reader, rôle Azure, demande envoyée, pas encore confirmée")
        #expect(SpokenRole.label(role: "Owner", source: .azureResource, scope: "kv", state: .permanent, locale: french)
                == "Owner, rôle Azure, kv, permanent")
        #expect(SpokenRole.label(role: "Reader", source: .azureResource, scope: "rg", state: .active(remaining: nil),
                                 error: "Network error", locale: english) == "Reader, Azure role, rg, active, Network error")
    }
}
