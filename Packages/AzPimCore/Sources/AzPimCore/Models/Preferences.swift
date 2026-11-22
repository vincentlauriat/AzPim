import Foundation

/// The app's own UserDefaults keys (`@AppStorage`), in one place so the legacy copy cannot miss one.
public enum PreferenceKeys {
    public static let allowLinkActivation = "deepLinks.allowActivation"
    public static let panelShowActive = "panel.showActive"
    public static let panelShowPermanent = "panel.showPermanent"
    public static let panelShowFavorites = "panel.showFavorites"
    public static let panelShowEligible = "panel.showEligible"
    /// Permanent assignments group of the Active card, collapsed by default (a new key: `panel.showPermanent` was
    /// expanded by default and would keep the group open for whoever already had it stored).
    public static let panelShowPermanentGroup = "panel.showPermanentGroup"
    /// Eligible card groups, by role type.
    public static let panelShowEligibleEntra = "panel.showEligibleEntra"
    public static let panelShowEligibleAzure = "panel.showEligibleAzure"
    public static let panelShowEligibleGroups = "panel.showEligibleGroups"

    public static let all: [String] = [allowLinkActivation, panelShowActive, panelShowPermanent,
                                       panelShowFavorites, panelShowEligible, panelShowPermanentGroup,
                                       panelShowEligibleEntra, panelShowEligibleAzure, panelShowEligibleGroups]

    /// Defaults domain of the 0.9.x releases, shipped as AzurePim (non-sandboxed: ~/Library/Preferences/<domain>.plist).
    /// It is also AzurePim's bundle id.
    public static let legacyDomain = "fr.vincentlauriat.azurepim"

    /// Set once the AzurePim setup (preferences, login item) was carried over. Not a legacy key: never copied.
    public static let legacyAdopted = "legacy.adopted"

    /// The app's keys set in `old` and not yet set in `current`. Sparkle `SU*`, AppKit `NS*` window state and any
    /// other key stay behind.
    public static func legacyValues(from old: [String: Any], notIn current: [String: Any]) -> [String: Any] {
        old.filter { all.contains($0.key) && current[$0.key] == nil }
    }

    /// Copies the app's keys from the AzurePim domain into `domain`, never overwriting a value already set there.
    /// Reads persistent domains only (no global or registration domain). Returns the copied keys, sorted.
    @discardableResult
    public static func copyLegacy(from oldDomain: String = legacyDomain, into defaults: UserDefaults,
                                  domain: String) -> [String] {
        let old = defaults.persistentDomain(forName: oldDomain) ?? [:]
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        let values = legacyValues(from: old, notIn: current)
        values.forEach { defaults.set($0.value, forKey: $0.key) }
        return values.keys.sorted()
    }
}
