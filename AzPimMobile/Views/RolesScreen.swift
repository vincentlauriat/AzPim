import AzPimCore
import SwiftData
import SwiftUI

/// The iPhone panel (compact width: iPhone, iPhone Duo folded), "Dials" design: the activation that ends first as a hero
/// card with a large dial, the other active roles as small cards, favorites as chips, eligible roles grouped by type.
/// Same rules as the Mac panel (`PanelModel`: one account per identity, one row per role, held roles left out of the
/// eligible list). Tap any role → its detail (`navigation.selection`); Activate / Deactivate on the row or card; swipe
/// an activation to extend it; Extend and Details also in context menus and VoiceOver actions; pull to refresh.
/// Sheets and the selection live in `MobileNavigation`, so they survive a switch to the split view.
struct RolesScreen: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize
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
                                    EligibleRoleRow(role: role, waiting: model.waiting(role, in: pendingRecords, now: store.now))
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
            .listSectionSpacing(.compact)
            .refreshable { await store.refresh() }
            .navigationTitle("AzPim")
            .toolbar { MobileToolbar() }
            .navigationDestination(item: $navigation.selection) { id in RoleDetailScreen(rowId: id) }
        }
    }

    // MARK: Active roles

    /// The hero, then the other activations and the permanent assignments: a 2-column grid, or one card per row at
    /// accessibility sizes (where each activation gets its swipe back). No active role: the empty dial.
    @ViewBuilder private func activeSection(_ model: PanelModel) -> some View {
        let others = Array(model.activations.dropFirst()) + model.permanents
        Section {
            if let hero = model.activations.first {
                HeroCard(assignment: hero.assignment, alsoPermanent: hero.alsoPermanent)
                    .cardRow()
                    .swipeActions(edge: .leading) { extendSwipe(hero.assignment) }
            } else if model.permanents.isEmpty {
                EmptyDialCard().cardRow()
            }
            if typeSize.isAccessibilitySize {
                ForEach(others) { row in
                    ActiveRoleCard(assignment: row.assignment, alsoPermanent: row.alsoPermanent)
                        .cardRow()
                        .swipeActions(edge: .leading) { extendSwipe(row.assignment) }
                }
            } else if !others.isEmpty {
                grid(others).cardRow()
            }
        }
    }

    private func grid(_ rows: [PanelAssignment]) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                GridRow {
                    ActiveRoleCard(assignment: rows[index].assignment, alsoPermanent: rows[index].alsoPermanent)
                    if index + 1 < rows.count {
                        ActiveRoleCard(assignment: rows[index + 1].assignment, alsoPermanent: rows[index + 1].alsoPermanent)
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    @ViewBuilder private func extendSwipe(_ assignment: ActiveAssignment) -> some View {
        if let role = assignment.eligibleRole, !store.isBusy(assignment), !store.isOffline {
            Button("Extend") { navigation.extend(role, store: store) }.tint(Theme.accentFill)
        }
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        Section("Favorites") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(favorites) { favorite in
                        FavoriteChip(name: favorite.name,
                                     running: runningFavorite == favorite.id || store.runningFavorites.contains(favorite.id)) {
                            Task { await start(favorite) }
                        }
                        .disabled(favorite.items.isEmpty || runningFavorite != nil || store.isOffline)
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
