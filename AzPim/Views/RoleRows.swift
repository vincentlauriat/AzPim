import AzPimCore
import Foundation

/// The rows of the Roles Window (Mac) and of the iPhone roles list (regular width): every eligible role of the
/// accounts in use, maybe active, plus the permanent assignments no eligible row already shows. Shared by both apps.
enum RoleRows {
    /// `roles` and `assignments`: every cached row; superseded ones (an Azure CLI account replaced by a Microsoft
    /// sign-in of the same identity) and ended activations are left out here.
    static func make(roles: [EligibleRole], assignments: [ActiveAssignment], supersession: Supersession,
                     now: Date) -> [RoleRow] {
        let activeRoles = roles.filter { role in role.account.map { !supersession.hides($0.id, role.source) } == true }
        let live = assignments.filter { row in
            row.isLive(at: now) && row.account.map { !supersession.hides($0.id, row.source) } == true
        }
        let permanentKeys = Set(live.filter { $0.assignmentType == .assigned }.map(\.facts.key))
        var list = activeRoles.map { role in
            RoleRow(role: role, assignment: live.first { $0.eligibleRole?.id == role.id && $0.assignmentType == .activated },
                    heldPermanently: permanentKeys.contains(role.heldKey))
        }
        // One row per permanent role. One also held as an activation is shown by that activation's eligible row
        // ("also permanent"), when that row is listed; otherwise it keeps its own permanent row.
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(activeRoles.map(\.id))
        list += RoleMerge.merge(live.map(\.facts)).compactMap { group -> ActiveAssignment? in
            guard group.type == .activated else { return byId[group.primaryId] }
            guard group.alsoPermanent else { return nil }
            if let role = byId[group.primaryId]?.eligibleRole, listed.contains(role.id) { return nil }
            return group.memberIds.compactMap { byId[$0] }.first { $0.assignmentType == .assigned }
        }.map { RoleRow(permanent: $0) }
        return list
    }

    /// The rows matching the filters (nil: any source, any account; empty search: every row).
    static func filter(_ rows: [RoleRow], source: RoleSource?, accountId: UUID?, state: RoleStateFilter,
                       search: String) -> [RoleRow] {
        rows.filter { row in
            (source == nil || row.source == source)
                && (accountId == nil || row.account?.id == accountId)
                && state.matches(row)
                && (search.isEmpty || row.searchText.localizedCaseInsensitiveContains(search))
        }
    }
}

/// One line of the Roles table: an eligible role (maybe active) or a permanent assignment. Its id stays the same
/// when the role is activated or deactivated (the eligible role's id), so a selection survives a refresh.
struct RoleRow: Identifiable {
    let id: String
    let role: EligibleRole?
    let assignment: ActiveAssignment?
    /// An eligible role also assigned permanently: it is held even without an activation.
    let heldPermanently: Bool

    init(role: EligibleRole, assignment: ActiveAssignment?, heldPermanently: Bool = false) {
        id = role.id
        self.role = role
        self.assignment = assignment
        self.heldPermanently = heldPermanently
    }

    init(permanent: ActiveAssignment) {
        id = permanent.id
        role = nil
        assignment = permanent
        heldPermanently = true
    }

    var source: RoleSource { role?.source ?? assignment?.source ?? .azureResource }
    var roleName: String { role?.roleName ?? assignment?.roleName ?? "" }
    var scopeName: String { role?.scopeName ?? assignment?.scopeName ?? "" }
    var scope: String { role?.scope ?? assignment?.scope ?? "" }
    var account: Account? { role?.account ?? assignment?.account }
    var isPermanent: Bool { role == nil }
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
    /// Raw and displayed names, so « Owner » and « Propriétaire » both match.
    var searchText: String { "\(roleName) \(scopeName) \(displayRoleName) \(displayScopeName) \(account?.upn ?? "")" }
}

/// State filter of the roles list.
enum RoleStateFilter: String, CaseIterable, Identifiable {
    case all = "All", eligible = "Eligible", active = "Active", permanent = "Permanent"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .eligible: String(localized: "Eligible")
        case .active: String(localized: "Active")
        case .permanent: String(localized: "Permanent")
        }
    }

    func matches(_ row: RoleRow) -> Bool {
        switch self {
        case .all: true
        case .eligible: !row.isPermanent && row.assignment == nil && !row.heldPermanently
        case .active: !row.isPermanent && (row.assignment != nil || row.heldPermanently)
        case .permanent: row.isPermanent
        }
    }
}

/// SF Symbol of a role source (Mac panel and Roles Window, iPhone role detail).
enum SourceIcon {
    static func name(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: "cloud"
        case .entraRole: "person.badge.key"
        case .pimGroup: "person.3"
        }
    }
}
