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
    let activations: [PanelAssignment]
    /// Permanent assignments not already shown as an activation, by name.
    let permanents: [PanelAssignment]
    /// Eligible roles not active right now (neither activated nor held permanently).
    let eligible: [EligibleRole]

    /// `accounts`: the accounts shown (superseded ones already left out).
    init(accounts: [Account], assignments: [ActiveAssignment], now: Date) {
        let shown = Set(accounts.map(\.id))
        let live = assignments.filter { $0.isLive(at: now) && $0.account.map { shown.contains($0.id) } == true }
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
        eligible = accounts.flatMap(\.eligibleRoles)
            .filter { !RoleMerge.isHeld(eligibleRoleId: $0.id, key: $0.heldKey, linkedEligibleIds: linked, heldKeys: held) }
            .sorted { ($0.roleName, $0.scopeName) < ($1.roleName, $1.scopeName) }
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
        case .entra: "Entra roles"
        case .azure: "Azure roles"
        case .groups: "PIM groups"
        }
    }
}

/// Small capsule naming the role type of a row: Entra / Azure / Group.
struct TypeTag: View {
    let source: RoleSource

    var text: String {
        switch source {
        case .entraRole: "Entra"
        case .azureResource: "Azure"
        case .pimGroup: "Group"
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
        .accessibilityLabel("\(title), \(count), \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(expanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

/// Active roles card: activations by expiry, then the permanent assignments in a group collapsed by default.
struct ActiveRolesCard: View {
    let model: PanelModel
    let emptyText: String
    let showAccount: Bool
    @AppStorage(PreferenceKeys.panelShowActive) private var showActive = true
    @AppStorage(PreferenceKeys.panelShowPermanentGroup) private var showPermanent = false

    var body: some View {
        DisclosureCard(title: "Active roles", icon: "bolt.fill", iconColor: Theme.active,
                       count: model.activations.count + model.permanents.count, expanded: $showActive) {
            if model.activations.isEmpty && model.permanents.isEmpty {
                EmptyLine(text: emptyText)
            }
            ForEach(Array(model.activations.enumerated()), id: \.element.id) { index, row in
                if index > 0 { RowDivider() }
                ActiveRow(assignment: row.assignment, alsoPermanent: row.alsoPermanent, showTypeTag: true)
            }
            if !model.permanents.isEmpty {
                if !model.activations.isEmpty { RowDivider(inset: 0) }
                GroupHeader(title: "Permanent", count: model.permanents.count, expanded: $showPermanent)
                if showPermanent {
                    ForEach(Array(model.permanents.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        PermanentRow(assignment: row.assignment, showAccount: showAccount, showTypeTag: true)
                    }
                }
            }
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
        DisclosureCard(title: "Eligible roles", icon: "key.horizontal.fill", iconColor: Theme.accent,
                       count: model.eligible.count, expanded: $showEligible) {
            if noAccount {
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
        if showHeader {
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
        let expanded = binding(type)
        GroupHeader(title: type.title, count: roles.count, expanded: expanded)
        if expanded.wrappedValue {
            ForEach(Array(roles.enumerated()), id: \.element.id) { index, role in
                if index > 0 { RowDivider() }
                EligibleRow(role: role, isActive: false,
                            pending: pendingRecords.first { $0.eligibleRoleId == role.id && $0.isWaiting(at: store.now) }?.status) {
                    activate(role)
                }
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
