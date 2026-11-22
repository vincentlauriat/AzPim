import AzPimCore
import Foundation

/// Where the last duration per role is kept: `[ActivationDuration.roleKey: ISO 8601 duration]`.
struct DurationMemory {
    var load: () -> [String: String]
    var save: ([String: String]) -> Void

    /// The preferences, under `PreferenceKeys.lastDurations`.
    static func defaults(_ defaults: UserDefaults) -> DurationMemory {
        DurationMemory(load: { (defaults.dictionary(forKey: PreferenceKeys.lastDurations) as? [String: String]) ?? [:] },
                       save: { defaults.set($0, forKey: PreferenceKeys.lastDurations) })
    }

    /// Nothing written to disk (tests).
    static func inMemory() -> DurationMemory {
        final class Box { var values: [String: String] = [:] }
        let box = Box()
        return DurationMemory(load: { box.values }, save: { box.values = $0 })
    }
}

/// Least-privilege durations (1.0 item 6): the last duration used per role, kept under a key that survives refreshes
/// and the Azure CLI → Microsoft sign-in supersede (`ActivationDuration.roleKey`).
extension RoleStore {
    /// Duration last sent for this role and accepted by Azure (sheet, favorite or Extend), if any.
    func lastDuration(for role: EligibleRole) -> String? {
        Self.durationKey(role).flatMap { durationMemory.load()[$0] }
    }

    /// Duration to preselect for this role: the last one used, else 1 h, capped by the policy.
    func defaultDurationMinutes(for role: EligibleRole) -> Int {
        ActivationDuration.defaultMinutes(lastUsed: lastDuration(for: role), policyMax: role.maxDuration)
    }

    /// ISO duration of a new favorite item for this role (same default as the sheet).
    func defaultFavoriteDuration(for role: EligibleRole) -> String {
        ActivationDuration.iso(defaultDurationMinutes(for: role))
    }

    func rememberDuration(_ duration: String, for role: EligibleRole) {
        guard let key = Self.durationKey(role), ISODuration.seconds(duration) != nil else { return }
        var all = durationMemory.load()
        all[key] = duration
        durationMemory.save(all)
    }

    private static func durationKey(_ role: EligibleRole) -> String? {
        guard let account = role.account else { return nil }
        return ActivationDuration.roleKey(tenantId: account.tenantId, source: role.source,
                                          roleDefinitionId: role.roleDefinitionId, roleName: role.roleName, scope: role.scope)
    }
}
