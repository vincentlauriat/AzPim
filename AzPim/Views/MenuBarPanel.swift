import AzPimCore
import SwiftData
import SwiftUI

/// Menu bar label (DesignBrief › Components): `key.fill` when nothing is active; otherwise count + next expiry,
/// orange at ≤ 15 min, red at ≤ 5 min. An hourglass follows while a request waits for approval (an SF Symbol, so
/// the status item keeps it a template image). Rendered at launch: also opens Onboarding on first run.
struct MenuBarLabel: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query private var accountList: [Account]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" })
    private var pendingRecords: [ActivationRecord]

    /// Rows of the accounts in use, one per role (superseded Azure CLI rows count for nothing).
    private var model: PanelModel {
        let supersession = store.supersession(accountList)
        let accounts = accountList.filter { !supersession.isRetired($0.id) }
        return PanelModel(accounts: accounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    var body: some View {
        let model = model
        label(activations: model.activations.map(\.assignment),
              badge: MenuBarBadge(activeCount: model.activations.count,
                                  pendingCount: model.pendingApprovalCount(in: pendingRecords)))
            .task {
                if !accounts.settings.onboardingCompleted {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    @ViewBuilder private func label(activations: [ActiveAssignment], badge: MenuBarBadge) -> some View {
        let style = accounts.settings.menuBarStyle
        let pending = badge.spokenPending.map { ", \($0)" } ?? ""
        if activations.isEmpty || style == .icon {
            HStack(spacing: 2) {
                Image(systemName: badge.keySymbol)
                if let symbol = badge.pendingSymbol { Image(systemName: symbol) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((activations.isEmpty ? "AzPim, no active role" : "AzPim, \(activations.count) active") + pending)
        } else {
            let remaining = activations.compactMap(\.endAt).min().map { $0.timeIntervalSince(store.now) }
            HStack(spacing: 3) {
                Image(systemName: badge.keySymbol)
                Text(text(count: activations.count, remaining: style == .iconCountTime ? remaining : nil))
                    .monospacedDigit()
                if let symbol = badge.pendingSymbol { Image(systemName: symbol) }
            }
            .foregroundStyle(Countdown.color(remaining))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AzPim, \(activations.count) active, next expiry in \(Countdown.spoken(remaining))" + pending)
        }
    }

    private func text(count: Int, remaining: TimeInterval?) -> String {
        guard let remaining else { return "\(count)" }
        return "\(count) · \(Countdown.short(remaining))"
    }
}

/// Menu Bar Panel (AppFlow), in the Juicy / Claude Cockpit look: a hero card with the active count and the next
/// expiry, collapsible cards (Active roles, Favorites, Eligible roles) and a settings-style action list.
struct MenuBarPanel: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    /// Requests that may still be waiting; `isWaiting` decides (a sent one stops blocking the row after 15 min).
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent" })
    private var pendingRecords: [ActivationRecord]
    @State private var activating: EligibleRole?
    @State private var contentHeight: CGFloat = 0
    @State private var query: String
    @FocusState private var searchFocused: Bool
    @AppStorage(PreferenceKeys.panelShowFavorites) private var showFavorites = true

    /// `initialQuery`: snapshots of a search only.
    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    private var supersession: Supersession { store.supersession(accountList) }
    /// Accounts in use: an Azure CLI account replaced by a Microsoft sign-in of the same identity is left out.
    private var activeAccounts: [Account] {
        let supersession = supersession
        return accountList.filter { !supersession.isRetired($0.id) }
    }
    /// Accounts shown, after the account filter (T4.4).
    private var shownAccounts: [Account] {
        let active = activeAccounts
        guard let filter = store.accountFilter, active.contains(where: { $0.id == filter }) else { return active }
        return active.filter { $0.id == filter }
    }
    private var model: PanelModel {
        PanelModel(accounts: shownAccounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    /// The panel must fit under the menu bar; past ~640 pt the main window is the better place.
    private var maxHeight: CGFloat {
        #if DEBUG
        if SnapshotRunner.directory != nil { return 1400 }   // full panel in screenshots
        #endif
        return max(320, min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 24))
    }

    var body: some View {
        Group {
            if let role = activating {
                ActivationSheet(role: role) { activating = nil }
                    .frame(width: Theme.panelWidth)
            } else {
                ScrollView(.vertical) {
                    content
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
                .frame(width: Theme.panelWidth, height: min(contentHeight > 0 ? contentHeight : 520, maxHeight))
            }
        }
        .background(WindowKeyObserver {
            store.panelOpenedAt = .now
            if !store.snapshotFrozen { query = "" }   // each open starts without a search (snapshots keep theirs)
            Task { await store.refreshIfStale() }
        })
    }

    private var content: some View {
        let model = model
        return VStack(spacing: 8) {
            header
            heroCard(model)
            errorBanners
            if RoleSearch.isEmpty(query) {
                ActiveRolesCard(model: model, emptyText: accountList.isEmpty ? "Add an account to see your roles" : "No active role",
                                showAccount: shownAccounts.count > 1)
                if !favorites.isEmpty { favoritesCard }
                EligibleRolesCard(model: model, accounts: shownAccounts, pendingRecords: pendingRecords,
                                  noAccount: accountList.isEmpty, noEligibleText: noEligibleText) { activating = $0 }
            } else {
                searchResults(model.filtered(by: query))
            }
            PanelActionList()
        }
        .padding(10)
    }

    /// Matching rows only, every group open; card counts are those of the matches.
    @ViewBuilder private func searchResults(_ found: PanelModel) -> some View {
        if found.isEmpty {
            EmptyLine(text: "No role matches")
                .padding(.horizontal, 14)
                .card()
        }
        if !found.activations.isEmpty || !found.permanents.isEmpty {
            ActiveRolesCard(model: found, emptyText: "", showAccount: shownAccounts.count > 1, searching: true)
        }
        if !found.eligible.isEmpty {
            EligibleRolesCard(model: found, accounts: shownAccounts, pendingRecords: pendingRecords, noAccount: false,
                              noEligibleText: noEligibleText, searching: true) { activating = $0 }
        }
    }

    // MARK: Header and hero

    /// Search field, and the account menu when several accounts are in use (T4.4).
    private var header: some View {
        HStack(spacing: 8) {
            PanelSearchField(query: $query, focused: $searchFocused)
            if activeAccounts.count > 1 { accountMenu }
        }
    }

    private var accountMenu: some View {
        @Bindable var store = store
        return Picker("Account", selection: $store.accountFilter) {
            Text("All accounts (\(activeAccounts.count))").tag(UUID?.none)
            ForEach(activeAccounts) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help("Accounts shown in the panel")
    }

    /// The activation that expires first, with its time left.
    private func nextActivation(_ activations: [ActiveAssignment]) -> (assignment: ActiveAssignment, remaining: TimeInterval)? {
        guard let next = activations.filter({ ($0.endAt ?? .distantPast) > store.now }).min(by: {
            ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture)
        }), let end = next.endAt else { return nil }
        return (next, end.timeIntervalSince(store.now))
    }

    private func heroCard(_ model: PanelModel) -> some View {
        let next = nextActivation(model.activations.map(\.assignment))
        let summary = HeroSummary(activeCount: model.activations.count, nextExpiry: next.map { Countdown.hero($0.remaining) },
                                  pendingCount: model.pendingApprovalCount(in: pendingRecords))
        return CompactHeroCard(summary: summary, activeCount: model.activations.count, remaining: next?.remaining,
                               nextRole: next.map { "\($0.assignment.roleName) · \($0.assignment.scopeName)" },
                               signedIn: !accountList.isEmpty)
    }

    // MARK: Banners

    private func bannerKinds(_ account: Account) -> [ErrorKind] {
        let kinds: Set<ErrorKind> = Set((store.refreshErrors[account.id] ?? [:]).values)
        return kinds.filter { $0 != .offline }.sorted { $0.message < $1.message }
    }

    /// One banner per distinct problem (Offline is shown in the hero card instead).
    @ViewBuilder private var errorBanners: some View {
        ForEach(shownAccounts) { account in
            ForEach(bannerKinds(account), id: \.message) { kind in
                ErrorBanner(kind: kind, account: activeAccounts.count > 1 ? account.upn : nil,
                            onSignIn: account.mode == .msal ? { Task { await store.refresh() } } : nil)
            }
        }
    }

    // MARK: Cards

    private var favoritesCard: some View {
        DisclosureCard(title: "Favorites", icon: "star.fill", iconColor: Theme.violet,
                       count: favorites.count, expanded: $showFavorites) {
            FavoriteChips(favorites: favorites)
        }
    }
}

extension MenuBarPanel {
    /// "No eligible role" only once a refresh read every source: an error or a first load is not that.
    fileprivate func noEligibleText(_ account: Account) -> String {
        if !(store.refreshErrors[account.id] ?? [:]).isEmpty { return "Couldn't load the eligible roles of \(account.upn)" }
        if account.lastRefreshAt == nil { return "Loading the eligible roles of \(account.upn)…" }
        return "No eligible PIM role for \(account.upn)"
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
