import AzPimCore
import SwiftData
import SwiftUI

/// The iPhone panel (compact width: iPhone, iPhone Duo folded): active roles with their countdown, favorites, eligible
/// roles grouped by type. Same rules as the Mac panel (`PanelModel`: one account per identity, one row per role, held
/// roles left out of the eligible list). Tap an eligible role → Activation Sheet; Deactivate on an active one; swipe
/// an activation to extend it; Details (context menu, VoiceOver action) pushes the role detail; pull to refresh.
/// Sheets and the selection live in `MobileNavigation`, so they survive a switch to the split view.
struct RolesScreen: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    /// Requests that may still be waiting; `isWaiting` decides (a sent one stops blocking the row after 15 min).
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent" })
    private var pendingRecords: [ActivationRecord]
    @State private var runningFavorite: UUID?

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
        @Bindable var navigation = navigation
        let model = model
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    StatusSection(accounts: activeAccounts)
                    activeSection(model)
                    if !favorites.isEmpty { favoritesSection }
                    ForEach(PanelRoleType.allCases, id: \.self) { type in
                        let roles = model.eligible.filter { $0.source == type.source }
                        if !roles.isEmpty {
                            Section(type.title) {
                                ForEach(roles) { role in
                                    EligibleRoleRow(role: role, waiting: model.waiting(role, in: pendingRecords, now: store.now)) {
                                        navigation.activating = $0
                                    }
                                    .contextMenu { detailsButton(role.id) }
                                    .accessibilityActions { detailsButton(role.id) }
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
            .toolbar { MobileToolbar() }
            .navigationDestination(item: $navigation.selection) { id in RoleDetailScreen(rowId: id) }
        }
    }

    private func detailsButton(_ rowId: String) -> some View {
        Button { navigation.selection = rowId } label: { Label("Details", systemImage: "info.circle") }
    }

    // MARK: Sections

    private func activeSection(_ model: PanelModel) -> some View {
        Section {
            if model.activations.isEmpty && model.permanents.isEmpty {
                Text("No active role").foregroundStyle(.secondary)
            }
            ForEach(model.activations) { row in
                ActiveRoleRow(assignment: row.assignment, alsoPermanent: row.alsoPermanent) { navigation.deactivating = $0 }
                    .swipeActions(edge: .leading) {
                        if let role = row.assignment.eligibleRole, !store.isBusy(row.assignment) {
                            Button("Extend") { navigation.extend(role, store: store) }.tint(Theme.accentFill)
                        }
                    }
                    .contextMenu { activeMenu(row.assignment) }
                    .accessibilityActions { activeMenu(row.assignment) }
            }
            ForEach(model.permanents) { row in
                ActiveRoleRow(assignment: row.assignment, alsoPermanent: false, deactivate: nil)
                    .contextMenu { detailsButton(row.assignment.id) }
                    .accessibilityActions { detailsButton(row.assignment.id) }
            }
        } header: {
            Text("Active roles")
        }
    }

    /// Extend and Details of an activation (its row in the roles list is its eligible role's). An activation whose
    /// eligibility is unknown (its source failed, or it was removed) has no row in the roles list: no Details.
    @ViewBuilder private func activeMenu(_ assignment: ActiveAssignment) -> some View {
        if let role = assignment.eligibleRole {
            if !store.isBusy(assignment) {
                Button { navigation.extend(role, store: store) } label: { Label("Extend", systemImage: "clock.arrow.circlepath") }
            }
            detailsButton(role.id)
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
        if let request = await store.startFavorite(favorite, fromPanel: true) { navigation.askingFavorite = request }
    }
}

/// Offline state, refresh errors and the last result, on top of the panel and of the roles list.
struct StatusSection: View {
    @Environment(RoleStore.self) private var store
    /// Accounts in use (retired ones left out).
    let accounts: [Account]

    var body: some View {
        let banners = accounts.flatMap { account in
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
                    ErrorBanner(kind: kind, account: accounts.count > 1 ? account.upn : nil,
                                onSignIn: { Task { await store.refresh() } })
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                if let recent { ResultStatusLine(result: recent) }
            }
        }
    }
}

/// Settings, History (with the count of requests waiting for an approver) and the refresh spinner.
struct MobileToolbar: ToolbarContent {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" })
    private var waiting: [ActivationRecord]

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { navigation.showHistory = true } label: {
                Label("History", systemImage: waiting.isEmpty ? "clock.arrow.circlepath" : "clock.badge.exclamationmark")
            }
            .accessibilityValue(waiting.isEmpty ? "" : String(localized: "\(waiting.count) pending approval"))
            Button { navigation.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
        ToolbarItem(placement: .topBarLeading) {
            if store.isRefreshing { ProgressView() }
        }
    }
}
