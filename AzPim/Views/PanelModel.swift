import AzPimCore
import SwiftUI

/// One active row of the panel: an activation (maybe also held permanently) or a permanent assignment.
struct PanelAssignment: Identifiable {
    let assignment: ActiveAssignment
    let alsoPermanent: Bool
    var id: String { assignment.id }
}

/// What the panel shows, after the one-account-per-identity, one-row-per-role and "already held" rules.
struct PanelModel {
    /// Activations, the one expiring first on top.
    private(set) var activations: [PanelAssignment]
    /// Permanent assignments not already shown as an activation, by name.
    private(set) var permanents: [PanelAssignment]
    /// Eligible roles not active right now (neither activated nor held permanently).
    private(set) var eligible: [EligibleRole]
    /// Eligible roles left out because they are already held, per account.
    let heldEligibleCount: [UUID: Int]
    let supersession: Supersession

    /// `accounts`: the accounts shown (retired ones already left out); superseded rows of the others are left out too.
    init(accounts: [Account], assignments: [ActiveAssignment], supersession: Supersession, now: Date) {
        self.supersession = supersession
        let shown = Set(accounts.map(\.id))
        let live = assignments.filter { row in
            row.isLive(at: now) && row.account.map { shown.contains($0.id) && !supersession.hides($0.id, row.source) } == true
        }
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = RoleMerge.merge(live.map(\.facts)).compactMap { row in
            byId[row.primaryId].map { PanelAssignment(assignment: $0, alsoPermanent: row.alsoPermanent) }
        }
        activations = merged.filter { $0.assignment.assignmentType == .activated }
            .sorted { ($0.assignment.endAt ?? .distantFuture) < ($1.assignment.endAt ?? .distantFuture) }
        permanents = merged.filter { $0.assignment.assignmentType == .assigned }
            .sorted { ($0.assignment.roleName, $0.assignment.scopeName) < ($1.assignment.roleName, $1.assignment.scopeName) }
        let linked = Set(live.compactMap { $0.eligibleRole?.id })
        let held = Set(live.map(\.facts.key))
        let candidates = accounts.flatMap(\.eligibleRoles).filter { role in
            role.account.map { !supersession.hides($0.id, role.source) } == true
        }
        let isHeld = { (role: EligibleRole) in
            RoleMerge.isHeld(eligibleRoleId: role.id, key: role.heldKey, linkedEligibleIds: linked, heldKeys: held)
        }
        eligible = candidates.filter { !isHeld($0) }.sorted { ($0.roleName, $0.scopeName) < ($1.roleName, $1.scopeName) }
        heldEligibleCount = candidates.filter(isHeld).reduce(into: [:]) { counts, role in
            if let id = role.account?.id { counts[id, default: 0] += 1 }
        }
    }

    /// The request still waiting for this role, including one sent through a superseded Azure CLI account.
    func waiting(_ role: EligibleRole, in records: [ActivationRecord], now: Date) -> ActivationRecord? {
        records.first {
            $0.isWaiting(at: now) && supersession.resolve(eligibleRoleId: $0.eligibleRoleId, source: $0.source) == role.id
        }
    }

    /// Eligible roles with a request waiting for an approver (a request just sent is not counted), including one
    /// sent through a superseded Azure CLI account. The menu bar badge counts every account in use; the hero counts
    /// the accounts the panel shows (account menu), so the two differ only while one account is picked.
    func pendingApprovalCount(in records: [ActivationRecord]) -> Int {
        let waiting = Set(records.filter { $0.status == .pendingApproval }.map {
            supersession.resolve(eligibleRoleId: $0.eligibleRoleId, source: $0.source)
        })
        return eligible.filter { waiting.contains($0.id) }.count
    }

    /// No row at all (after a search).
    var isEmpty: Bool { activations.isEmpty && permanents.isEmpty && eligible.isEmpty }

    /// The rows matching the panel search: role name, scope or group name, role type, tenant name.
    func filtered(by query: String) -> PanelModel {
        guard !RoleSearch.isEmpty(query) else { return self }
        let matches = { (name: String, scope: String, source: RoleSource, tenant: String?) in
            // Raw and displayed names: « Owner » and « Propriétaire », « Directory » and « Annuaire » both match.
            RoleSearch.matches(query, fields: [name, scope, DisplayName.role(name, source: source),
                                               DisplayName.scope(scope, source: source), TypeTag.text(source),
                                               PanelRoleType.allCases.first { $0.source == source }?.title ?? "",
                                               tenant ?? ""])
        }
        var copy = self
        copy.activations = activations.filter { row in
            let item = row.assignment
            return matches(item.roleName, item.scopeName, item.source, item.account?.tenantName)
        }
        copy.permanents = permanents.filter { row in
            let item = row.assignment
            return matches(item.roleName, item.scopeName, item.source, item.account?.tenantName)
        }
        copy.eligible = eligible.filter { matches($0.roleName, $0.scopeName, $0.source, $0.account?.tenantName) }
        return copy
    }
}

/// Role types in the panel order: Entra roles, Azure roles, PIM groups.
enum PanelRoleType: CaseIterable {
    case entra, azure, groups

    var source: RoleSource {
        switch self {
        case .entra: .entraRole
        case .azure: .azureResource
        case .groups: .pimGroup
        }
    }

    var title: String {
        switch self {
        case .entra: String(localized: "Entra roles")
        case .azure: String(localized: "Azure roles")
        case .groups: String(localized: "PIM groups")
        }
    }
}

/// Small capsule naming the role type of a row: Entra / Azure / Group.
struct TypeTag: View {
    let source: RoleSource

    var text: String { Self.text(source) }

    /// Nonisolated: the panel search matches on it too.
    nonisolated static func text(_ source: RoleSource) -> String {
        switch source {
        case .entraRole: String(localized: "Entra")
        case .azureResource: String(localized: "Azure")
        case .pimGroup: String(localized: "Group")
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.slate)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.track, in: Capsule())
            .fixedSize()
    }
}
