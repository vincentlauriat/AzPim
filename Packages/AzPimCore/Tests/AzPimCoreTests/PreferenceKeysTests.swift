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
        #expect(PreferenceKeys.all.contains(PreferenceKeys.quickActivateShortcut))
    }

    /// On dictionaries: a real defaults domain would leave a plist in ~/Library/Preferences after the test.
    @Test func copiesOnlyMissingAppKeys() {
        let old: [String: Any] = ["deepLinks.allowActivation": false, "panel.showFavorites": false,
                                  "SUHasLaunchedBefore": true]
        var current: [String: Any] = ["panel.showFavorites": true]

        let copied = PreferenceKeys.copyLegacy(old: old, current: current) { current[$0] = $1 }

        #expect(copied == ["deepLinks.allowActivation"])
        #expect(current["deepLinks.allowActivation"] as? Bool == false)
        #expect(current["panel.showFavorites"] as? Bool == true)   // already set: not overwritten
        #expect(current["SUHasLaunchedBefore"] == nil)
    }

    @Test func noLegacyDomainCopiesNothing() {
        var writes = 0
        #expect(PreferenceKeys.copyLegacy(old: [:], current: [:]) { _, _ in writes += 1 }.isEmpty)
        #expect(writes == 0)
    }
}
