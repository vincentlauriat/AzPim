import AzPimCore
import Foundation
import SwiftData

/// Where the last duration per role is kept: `[ActivationDuration.roleKey: ISO 8601 duration]`.
struct DurationMemory {
    var load: () -> [String: String]
    var save: ([String: String]) -> Void

    /// The preferences, under `PreferenceKeys.lastDurations`. Values of another type are ignored.
    static func defaults(_ defaults: UserDefaults) -> DurationMemory {
        DurationMemory(load: { defaults.dictionary(forKey: PreferenceKeys.lastDurations)?.compactMapValues { $0 as? String } ?? [:] },
                       save: { defaults.set($0, forKey: PreferenceKeys.lastDurations) })
    }

    /// Nothing written to disk (tests, snapshots).
    static func inMemory() -> DurationMemory {
        final class Box { var values: [String: String] = [:] }
        let box = Box()
        return DurationMemory(load: { box.values }, save: { box.values = $0 })
    }
}

/// Least-privilege durations (1.0 item 6): the last duration chosen in the Activation Sheet per role, kept under a key
/// that survives refreshes and the Azure CLI → Microsoft sign-in supersede (`ActivationDuration.roleKey`).
extension RoleStore {
    /// Duration last chosen in the sheet for this role and accepted by Azure, if any.
    func lastDuration(for role: EligibleRole) -> String? {
        Self.durationKey(role).flatMap { durationMemory.load()[$0] }
    }

    /// Duration to preselect for this role: the last one chosen, else 1 h, capped by the policy.
    func defaultDurationMinutes(for role: EligibleRole) -> Int {
        ActivationDuration.defaultMinutes(lastUsed: lastDuration(for: role), policyMax: role.maxDuration)
    }

    /// ISO duration of a new favorite item for this role (same default as the sheet).
    func defaultFavoriteDuration(for role: EligibleRole) -> String {
        ActivationDuration.iso(defaultDurationMinutes(for: role))
    }

    /// Activation Sheet › Activate: the only request whose duration becomes the role's default.
    func activateFromSheet(_ role: EligibleRole, input: ActivationInput, fromPanel: Bool) async -> RequestStatus? {
        await activate(role, input: input, fromPanel: fromPanel, remembersDuration: true)
    }

    func rememberDuration(_ duration: String, for role: EligibleRole) {
        guard let key = Self.durationKey(role), ISODuration.seconds(duration) != nil else { return }
        var all = durationMemory.load()
        all[key] = duration
        durationMemory.save(all)
    }

    /// Keeps only the durations of roles still cached (after each refresh's history purge, and after an account is
    /// removed or all local data deleted). The remembered ticket fields are pruned with them.
    func pruneDurations() {
        pruneTickets()
        let all = durationMemory.load()
        guard !all.isEmpty else { return }
        let roles = (try? context.fetch(FetchDescriptor<EligibleRole>())) ?? []
        let kept = Set(roles.compactMap(Self.durationKey))
        let pruned = all.filter { kept.contains($0.key) }
        if pruned.count != all.count { durationMemory.save(pruned) }
    }

    private static func durationKey(_ role: EligibleRole) -> String? {
        guard let account = role.account, !account.isDeleted else { return nil }
        return ActivationDuration.roleKey(identity: account.identity, source: role.source,
                                          roleDefinitionId: role.roleDefinitionId, roleName: role.roleName, scope: role.scope)
    }
}
