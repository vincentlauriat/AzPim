import Foundation
import Testing
@testable import AzPimCore

/// Copy of the app's own preferences from the AzurePim (0.9.x) defaults domain.
struct PreferenceKeysTests {
    @Test func keepsOnlyTheAppKeysNotSetYet() {
        let old: [String: Any] = [
            "deepLinks.allowActivation": false,
            "panel.showEligible": false,
            "panel.showActive": false,
            "SUEnableAutomaticChecks": false,
            "SULastCheckTime": Date(),
            "NSWindow Frame main": "0 0 800 600",
            "NSStatusItem Visible Item-0": true
        ]
        let current: [String: Any] = ["panel.showActive": true]
        let copied = PreferenceKeys.legacyValues(from: old, notIn: current)
        #expect(Set(copied.keys) == ["deepLinks.allowActivation", "panel.showEligible"])
        #expect(copied["deepLinks.allowActivation"] as? Bool == false)
    }

    @Test func everyKeyIsAnAppKey() {
        #expect(PreferenceKeys.all.count == Set(PreferenceKeys.all).count)
        #expect(PreferenceKeys.all.allSatisfy { !$0.hasPrefix("SU") && !$0.hasPrefix("NS") })
        #expect(PreferenceKeys.all.contains(PreferenceKeys.allowLinkActivation))
    }

    @Test func copiesBetweenRealDefaultsDomains() throws {
        let oldDomain = "azpim-tests-old-\(UUID().uuidString)"
        let newDomain = "azpim-tests-new-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: newDomain))
        defer {
            defaults.removePersistentDomain(forName: oldDomain)
            defaults.removePersistentDomain(forName: newDomain)
        }
        defaults.setPersistentDomain(["deepLinks.allowActivation": false, "panel.showFavorites": false,
                                      "SUHasLaunchedBefore": true], forName: oldDomain)
        defaults.set(true, forKey: "panel.showFavorites")

        let copied = PreferenceKeys.copyLegacy(from: oldDomain, into: defaults, domain: newDomain)

        #expect(copied == ["deepLinks.allowActivation"])
        #expect(defaults.object(forKey: "deepLinks.allowActivation") as? Bool == false)
        #expect(defaults.bool(forKey: "panel.showFavorites"))   // already set: not overwritten
        #expect(defaults.persistentDomain(forName: newDomain)?["SUHasLaunchedBefore"] == nil)
    }

    @Test func noLegacyDomainCopiesNothing() throws {
        let newDomain = "azpim-tests-new-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: newDomain))
        defer { defaults.removePersistentDomain(forName: newDomain) }
        #expect(PreferenceKeys.copyLegacy(from: "azpim-tests-missing-\(UUID().uuidString)", into: defaults,
                                          domain: newDomain).isEmpty)
    }
}
