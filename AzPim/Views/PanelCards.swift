import AzPimCore
import SwiftData
import SwiftUI

/// Collapsible group header inside a card: label with a count and a chevron.
struct GroupHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
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
        .accessibilityAddTraits(.isHeader)
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
    /// VoiceOver « Activate… » of a row: the Activation Sheet of its role.
    var openSheet: ((EligibleRole) -> Void)?
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
                          selected: row.id == selectedId, keyboardConfirm: confirmBinding(row.id),
                          openSheet: row.assignment.eligibleRole.flatMap { role in openSheet.map { open in { open(role) } } })
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
    /// VoiceOver « Activate now »: the quick activation.
    var activateNow: ((EligibleRole) -> Void)?
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
                    .accessibilityAddTraits(.isHeader)
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
                            selected: role.id == selectedId, activateNow: activateNow.map { quick in { quick(role) } }) {
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
