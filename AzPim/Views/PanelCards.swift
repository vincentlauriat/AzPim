import AzPimCore
import SwiftData
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
            RoleSearch.matches(query, fields: [name, scope, TypeTag.text(source),
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

/// Collapsible group header inside a card: label with a count and a chevron.
struct GroupHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                SectionLabel(text: "\(title) · \(count)")
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? String(localized: "\(title), \(count), expanded")
                                     : String(localized: "\(title), \(count), collapsed"))
        .accessibilityHint(expanded ? String(localized: "Hide \(title)") : String(localized: "Show \(title)"))
    }
}

/// Active roles card: activations by expiry, then the permanent assignments in a group collapsed by default.
struct ActiveRolesCard: View {
    let model: PanelModel
    let emptyText: String
    let showAccount: Bool
    /// A search is active: every group is open and the empty line is left to the panel.
    var searching = false
    /// Row selected with the keyboard, and the one whose Deactivate question ⌫ asked.
    var selectedId: String?
    var confirmId: Binding<String?>?
    @AppStorage(PreferenceKeys.panelShowActive) private var showActive = true
    @AppStorage(PreferenceKeys.panelShowPermanentGroup) private var showPermanent = false

    var body: some View {
        // The badge counts activations, like the hero card; the Permanent group shows its own count.
        DisclosureCard(title: String(localized: "Active roles"), icon: "bolt.fill", iconColor: Theme.active,
                       count: model.activations.count, expanded: searching ? .constant(true) : $showActive) {
            if model.activations.isEmpty && model.permanents.isEmpty && !searching {
                EmptyLine(text: emptyText)
            }
            ForEach(Array(model.activations.enumerated()), id: \.element.id) { index, row in
                if index > 0 { RowDivider() }
                ActiveRow(assignment: row.assignment, alsoPermanent: row.alsoPermanent, showTypeTag: true,
                          selected: row.id == selectedId, keyboardConfirm: confirmBinding(row.id))
                    .id(row.id)
            }
            if !model.permanents.isEmpty {
                if !model.activations.isEmpty { RowDivider(inset: 0) }
                GroupHeader(title: String(localized: "Permanent"), count: model.permanents.count,
                            expanded: searching ? .constant(true) : $showPermanent)
                if showPermanent || searching {
                    ForEach(Array(model.permanents.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        PermanentRow(assignment: row.assignment, showAccount: showAccount, showTypeTag: true)
                    }
                }
            }
        }
    }
}

extension ActiveRolesCard {
    fileprivate func confirmBinding(_ id: String) -> Binding<Bool>? {
        confirmId.map { confirm in
            Binding(get: { confirm.wrappedValue == id }, set: { if !$0, confirm.wrappedValue == id { confirm.wrappedValue = nil } })
        }
    }
}

/// Eligible roles card: one collapsible group per role type (Entra, Azure, PIM groups), per tenant when several.
struct EligibleRolesCard: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let model: PanelModel
    /// Accounts shown (superseded ones left out).
    let accounts: [Account]
    /// Requests that may still be waiting (`isWaiting` decides).
    let pendingRecords: [ActivationRecord]
    let noAccount: Bool
    let noEligibleText: (Account) -> String
    /// A search is active: every group is open and only matching rows show (no empty or consent lines).
    var searching = false
    /// Row selected with the keyboard.
    var selectedId: String?
    let activate: (EligibleRole) -> Void
    @AppStorage(PreferenceKeys.panelShowEligible) private var showEligible = true
    @AppStorage(PreferenceKeys.panelShowEligibleEntra) private var showEntra = true
    @AppStorage(PreferenceKeys.panelShowEligibleAzure) private var showAzure = true
    @AppStorage(PreferenceKeys.panelShowEligibleGroups) private var showGroups = true

    /// Tenants in account order, without repeats.
    private var tenants: [String] {
        var seen = Set<String>()
        return accounts.map { $0.tenantId.lowercased() }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        DisclosureCard(title: String(localized: "Eligible roles"), icon: "key.horizontal.fill", iconColor: Theme.accent,
                       count: model.eligible.count, expanded: searching ? .constant(true) : $showEligible) {
            if noAccount && !searching {
                Button("Add an account…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .padding(.vertical, 6)
            }
            ForEach(tenants, id: \.self) { tenant in
                tenantSection(tenant, showHeader: tenants.count > 1)
            }
        }
    }

    @ViewBuilder private func tenantSection(_ tenant: String, showHeader: Bool) -> some View {
        let tenantAccounts = accounts.filter { $0.tenantId.lowercased() == tenant }
        let ids = Set(tenantAccounts.map(\.id))
        let roles = model.eligible.filter { $0.account.map { ids.contains($0.id) } == true }
        if showHeader && !(searching && roles.isEmpty) {
            HStack {
                SectionLabel(text: tenantAccounts.first.map { $0.tenantName ?? $0.tenantId } ?? tenant)
                Spacer()
            }
            .padding(.top, 6)
        }
        ForEach(PanelRoleType.allCases, id: \.self) { type in
            let typed = roles.filter { $0.source == type.source }
            if !typed.isEmpty { group(type, roles: typed) }
        }
        if !searching { tenantNotes(tenantAccounts, roles: roles) }
    }

    /// Why a tenant shows no row, and the admin consent link.
    @ViewBuilder private func tenantNotes(_ tenantAccounts: [Account], roles: [EligibleRole]) -> some View {
        if roles.isEmpty, tenantAccounts.contains(where: { (model.heldEligibleCount[$0.id] ?? 0) > 0 }) {
            EmptyLine(text: String(localized: "All eligible roles are active"))
        }
        ForEach(tenantAccounts) { account in
            // No eligibility at all: say why (error, first load, or truly none).
            if account.eligibleRoles.isEmpty {
                EmptyLine(text: noEligibleText(account))
            }
            if account.directoryAccess == .consentRequired {
                Button {
                    openWindow(id: WindowID.consent, value: account.id)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Entra roles: admin consent required", systemImage: "info.circle")
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func group(_ type: PanelRoleType, roles: [EligibleRole]) -> some View {
        let expanded = searching ? .constant(true) : binding(type)
        GroupHeader(title: type.title, count: roles.count, expanded: expanded)
        if expanded.wrappedValue {
            ForEach(Array(roles.enumerated()), id: \.element.id) { index, role in
                if index > 0 { RowDivider() }
                EligibleRow(role: role, isActive: false, pending: model.waiting(role, in: pendingRecords, now: store.now)?.status,
                            selected: role.id == selectedId) {
                    activate(role)
                }
                .id(role.id)
            }
        }
    }

    private func binding(_ type: PanelRoleType) -> Binding<Bool> {
        switch type {
        case .entra: $showEntra
        case .azure: $showAzure
        case .groups: $showGroups
        }
    }
}
