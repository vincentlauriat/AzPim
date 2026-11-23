import AzPimCore
import SwiftData
import SwiftUI

/// The iPhone panel (compact layout, 2.0 step 2): active roles with their countdown, favorites, eligible roles grouped
/// by type. Same rules as the Mac panel (`PanelModel`: one account per identity, one row per role, held roles left out
/// of the eligible list). Tap an eligible role → Activation Sheet; Deactivate on an active one; pull to refresh.
struct RolesScreen: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    /// Requests that may still be waiting; `isWaiting` decides (a sent one stops blocking the row after 15 min).
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent" })
    private var pendingRecords: [ActivationRecord]
    @State private var activating: EligibleRole?
    @State private var askingFavorite: FavoriteRunRequest?
    @State private var deactivating: ActiveAssignment?
    @State private var runningFavorite: UUID?
    @State private var showSettings: Bool

    init(showSettings: Bool = false, activating: EligibleRole? = nil) {
        _showSettings = State(initialValue: showSettings)
        _activating = State(initialValue: activating)
    }

    private var supersession: Supersession { store.supersession(accountList) }
    /// Accounts in use: an Azure CLI account replaced by a Microsoft sign-in of the same identity is left out.
    private var activeAccounts: [Account] {
        let supersession = supersession
        return accountList.filter { !supersession.isRetired($0.id) }
    }
    private var model: PanelModel {
        PanelModel(accounts: activeAccounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    var body: some View {
        let model = model
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    statusSection
                    activeSection(model)
                    if !favorites.isEmpty { favoritesSection }
                    ForEach(PanelRoleType.allCases, id: \.self) { type in
                        let roles = model.eligible.filter { $0.source == type.source }
                        if !roles.isEmpty {
                            Section(type.title) {
                                ForEach(roles) { role in
                                    EligibleRoleRow(role: role, waiting: model.waiting(role, in: pendingRecords, now: store.now)) {
                                        activating = $0
                                    }
                                }
                            }
                            .id(type.title)
                        }
                    }
                }
                #if DEBUG
                // Demo screenshots of the eligible roles (`AZPIM_DEMO=eligible`): no scrolling from the command line.
                .task { if MobileDemo.screen == "eligible" { proxy.scrollTo(PanelRoleType.entra.title, anchor: .top) } }
                #endif
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .navigationTitle("AzPim")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.isRefreshing { ProgressView() }
                }
            }
        }
        .sheet(item: $activating) { role in
            ScrollView { ActivationSheet(role: role) { activating = nil }.padding(.top, 8) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $askingFavorite) { request in
            ScrollView { FavoriteActivationSheet(request: request) { askingFavorite = nil }.padding(.top, 8) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) { MobileSettingsView() }
        .confirmationDialog(deactivating.map { "Deactivate \($0.displayRoleName)?" } ?? "",
                            isPresented: Binding(get: { deactivating != nil }, set: { if !$0 { deactivating = nil } }),
                            titleVisibility: .visible, presenting: deactivating) { assignment in
            Button("Deactivate", role: .destructive) { Task { await store.deactivate(assignment) } }
        }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        let banners = activeAccounts.flatMap { account in
            Set((store.refreshErrors[account.id] ?? [:]).values).filter { $0 != .offline }
                .sorted { $0.message < $1.message }.map { (account, $0) }
        }
        let recent = store.lastResult.flatMap { $0.isRecent(at: store.now) ? $0 : nil }
        if store.isOffline || !banners.isEmpty || recent != nil {
            Section {
                if store.isOffline, let lastOnline = store.lastOnline {
                    Label("Offline · data from \(lastOnline.appFormatted(date: .omitted, time: .shortened))",
                          systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(Theme.warning)
                }
                ForEach(banners, id: \.1.message) { account, kind in
                    ErrorBanner(kind: kind, account: activeAccounts.count > 1 ? account.upn : nil,
                                onSignIn: { Task { await store.refresh() } })
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                if let recent { ResultStatusLine(result: recent) }
            }
        }
    }

    private func activeSection(_ model: PanelModel) -> some View {
        Section {
            if model.activations.isEmpty && model.permanents.isEmpty {
                Text("No active role").foregroundStyle(.secondary)
            }
            ForEach(model.activations) { row in
                ActiveRoleRow(assignment: row.assignment, alsoPermanent: row.alsoPermanent) { deactivating = $0 }
            }
            ForEach(model.permanents) { row in
                ActiveRoleRow(assignment: row.assignment, alsoPermanent: false, deactivate: nil)
            }
        } header: {
            Text("Active roles")
        }
    }

    private var favoritesSection: some View {
        Section("Favorites") {
            ForEach(favorites) { favorite in
                Button {
                    Task { await start(favorite) }
                } label: {
                    HStack {
                        Label(favorite.name, systemImage: "star.fill").foregroundStyle(Theme.violet)
                        Spacer()
                        if runningFavorite == favorite.id || store.runningFavorites.contains(favorite.id) {
                            ProgressView()
                        } else {
                            Text("\(favorite.items.count) roles").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(favorite.items.isEmpty || runningFavorite != nil || store.isOffline)
            }
            if let toast = store.favoriteToast {
                let name = favorites.first { $0.id == toast.favoriteId }?.name ?? String(localized: "Favorite")
                Text("\(name): \(toast.text)").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Runs the favorite at once, or opens the grouped sheet when a role needs a justification or a ticket.
    private func start(_ favorite: Favorite) async {
        runningFavorite = favorite.id
        defer { runningFavorite = nil }
        if let request = await store.startFavorite(favorite, fromPanel: true) { askingFavorite = request }
    }
}

/// An activation (countdown, Deactivate) or a permanent assignment (read-only).
private struct ActiveRoleRow: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    let alsoPermanent: Bool
    /// Nil for a permanent assignment.
    let deactivate: ((ActiveAssignment) -> Void)?

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { store.now.timeIntervalSince(assignment.startAt) < 300 }
    private var remaining: TimeInterval? { assignment.endAt.map { $0.timeIntervalSince(store.now) } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoleLabel(name: assignment.displayRoleName, scope: assignment.displayScopeName, source: assignment.source,
                      tenant: nil)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                if let remaining {
                    Text(Countdown.compact(remaining))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.remaining(remaining))
                        .accessibilityLabel(Countdown.spoken(remaining))
                } else {
                    Text("Permanent").font(.footnote).foregroundStyle(.secondary)
                }
                if alsoPermanent { Text("also permanent").font(.caption2).foregroundStyle(.secondary) }
                if let deactivate {
                    if store.isBusy(assignment) {
                        ProgressView()
                    } else {
                        Button("Deactivate", role: .destructive) { deactivate(assignment) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(tooRecent || store.isOffline)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        if let error = store.rowErrors[assignment.id] {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
    }
}

/// An eligible role: tap to open the Activation Sheet.
private struct EligibleRoleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let waiting: ActivationRecord?
    let activate: (EligibleRole) -> Void

    var body: some View {
        Button {
            activate(role)
        } label: {
            HStack(spacing: 12) {
                RoleLabel(name: role.displayRoleName, scope: role.displayScopeName, source: role.source, tenant: nil)
                Spacer(minLength: 4)
                if store.busy.contains(role.id) {
                    ProgressView()
                } else if waiting?.status == .pendingApproval {
                    Label("Pending approval", systemImage: "hourglass").labelStyle(.iconOnly).foregroundStyle(Theme.warning)
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Activate…")
        if let error = store.rowErrors[role.id] {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
    }
}

/// Role name, scope and type tag.
private struct RoleLabel: View {
    let name: String
    let scope: String
    let source: RoleSource
    let tenant: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                TypeTag(source: source)
                Text(scope).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
