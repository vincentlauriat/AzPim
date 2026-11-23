import Foundation
@testable import AzPimCore
import Testing

let english = Locale(identifier: "en_US")
let french = Locale(identifier: "fr_FR")

/// Formatter output with ordinary spaces: the system may put a no-break or narrow no-break space between a number and
/// its unit, depending on the OS version.
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

/// French and English strings of the core (its `.strings` / `.stringsdict`), with an explicit locale.
struct LocalizationTests {
    @Test func heroSummaryPlurals() {
        #expect(HeroSummary(activeCount: 0, nextExpiry: nil, pendingCount: 0, locale: french).line == "0 actif")
        #expect(HeroSummary(activeCount: 1, nextExpiry: "42 min", pendingCount: 0, locale: french).line
                == "1 actif · prochaine expiration dans 42 min")
        #expect(HeroSummary(activeCount: 4, nextExpiry: nil, pendingCount: 2, locale: french).line
                == "4 actifs · 2 en attente")
        #expect(HeroSummary(activeCount: 1, nextExpiry: "42m", pendingCount: 1, locale: english).line
                == "1 active · next expiry in 42m · 1 pending")
    }

    @Test func spokenPendingPlurals() {
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 1).spokenPending(locale: french) == "1 demande en attente d’approbation")
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 3).spokenPending(locale: french) == "3 demandes en attente d’approbation")
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 1).spokenPending(locale: english) == "1 request waiting for approval")
    }

    @Test func requestDecisionInFrench() {
        let text = RequestDecision.notification(status: .denied, roleName: "Owner", scopeName: "rg", locale: french)
        #expect(text?.title == "Demande refusée\u{00A0}: Owner")
        #expect(text?.body == "rg — l’approbateur a refusé la demande.")
    }

    @Test func durationLabels() {
        #expect(plain(ISODuration.label(5_400, locale: french)) == "1 h 30 min")
        #expect(plain(ISODuration.label(7_200, locale: french)) == "2 h")
        #expect(plain(ISODuration.label(2_700, locale: french)) == "45 min")
        #expect(plain(ISODuration.label(5_400, locale: english)) == "1 hr 30 min")
        #expect(plain(ActivationBlock.durationTooLong(maxMinutes: 480).message(locale: french))
                == "La stratégie autorise 8 h au maximum.")
        #expect(plain(ErrorKind.throttled(retryAfter: nil).message(locale: french))
                == "Microsoft limite les requêtes — réessayez dans 30 s.")
        #expect(plain(ErrorKind.throttled(retryAfter: 90).message(locale: english))
                == "Microsoft is throttling requests — try again in 1 min 30 sec.")
    }

    @Test func favoriteSummaryInFrench() {
        let summary = FavoriteRun.summary([.init(roleName: "Reader", status: .provisioned),
                                           .init(roleName: "Owner", status: .sent),
                                           .init(roleName: "Contributor", status: nil)], locale: french)
        #expect(summary == "Activés\u{00A0}: 1 sur 3, 1 envoyée, pas encore confirmée — Contributor: échec")
    }

    @Test func positionalArgumentsKeepTheirOrder() {
        #expect(Validation.Failure.outOfRange("refreshIntervalMinutes", 1...30).userMessage(locale: french)
                == "Intervalle d’actualisation\u{00A0}: entre 1 et 30")
        #expect(Validation.Failure.tooLong("name", max: 40).userMessage(locale: english) == "Name is limited to 40 characters")
    }

    /// A key the tables miss falls back to English silently: every sentence must read differently in French.
    @Test func everyMessageIsTranslated() {
        let blocks: [ActivationBlock] = [.inProgress, .pending, .offline, .durationTooLong(maxMinutes: 90), .durationTooShort,
                                         .justificationRequired, .justificationTooLong, .ticketSystemRequired,
                                         .ticketSystemTooLong, .ticketRequired, .ticketTooLong]
        let errors: [ErrorKind] = [.offline, .timedOut, .throttled(retryAfter: 10), .cliNotFound, .cliExpired(command: "az login"),
                                   .cliStepUp(command: "az login"), .interactionRequired, .consentRequired, .forbidden("x")]
        let failures: [Validation.Failure] = [.empty("name"), .empty("justification"), .empty("ticket"), .empty("ticketSystem"),
                                              .empty("duration"), .tooLong("justification", max: 500), .outOfRange("duration", 5...60),
                                              .invalidFormat("clientId"), .invalidFormat("azCLIPath"), .duplicate("name"),
                                              .duplicate("ticket"), .exceedsPolicy(max: 3_600)]
        var pairs = blocks.map { ($0.message(locale: english), $0.message(locale: french)) }
        pairs += errors.map { ($0.message(locale: english), $0.message(locale: french)) }
        pairs += failures.map { ($0.userMessage(locale: english), $0.userMessage(locale: french)) }
        for status in [RequestStatus.provisioned, .denied, .failed, .canceled] {
            let inEnglish = RequestDecision.notification(status: status, roleName: "R", scopeName: "S", locale: english)
            let inFrench = RequestDecision.notification(status: status, roleName: "R", scopeName: "S", locale: french)
            pairs += [(inEnglish?.title ?? "", inFrench?.title ?? ""), (inEnglish?.body ?? "", inFrench?.body ?? "")]
        }
        pairs.append((PaletteCommand.alreadyActiveHint(locale: english), PaletteCommand.alreadyActiveHint(locale: french)))
        for (source, translated) in pairs {
            #expect(!translated.isEmpty && source != translated, "not translated: \(source)")
        }
    }

    @Test func extendPlanReasonsInFrench() {
        let plan = ExtendPlan.decide(policy: RolePolicy(requiresMFA: true), lastJustification: "x", lastDuration: nil,
                                     activeSince: .distantPast, locale: french)
        #expect(plan == .blocked("Ce rôle exige la MFA\u{00A0}: ouvrez le panneau pour l’activer à nouveau."))
    }

    /// A language the core has no table for reads English, not whatever `Bundle.module` would pick for the system.
    @Test func unsupportedLanguageFallsBackToEnglish() {
        let german = Locale(identifier: "de_DE")
        #expect(L10n.bundle(for: german).bundlePath.hasSuffix("en.lproj"))
        #expect(HeroSummary(activeCount: 2, nextExpiry: nil, pendingCount: 1, locale: german).line == "2 active · 1 pending")
        #expect(MenuBarBadge(activeCount: 0, pendingCount: 1).spokenPending(locale: german) == "1 request waiting for approval")
    }
}
