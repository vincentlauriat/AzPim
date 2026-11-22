import AzPimCore
import SwiftData
import SwiftUI

/// Menu bar label (DesignBrief › Components): `key.fill` when nothing is active; otherwise count + next expiry,
/// orange at ≤ 15 min, red at ≤ 5 min. Rendered at launch: also opens Onboarding on first run.
struct MenuBarLabel: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query private var accountList: [Account]

    /// Activations of the accounts in use, one per role (superseded Azure CLI rows count for nothing).
    private var activations: [ActiveAssignment] {
        let supersession = store.supersession(accountList)
        let accounts = accountList.filter { !supersession.isRetired($0.id) }
        return PanelModel(accounts: accounts, assignments: assignments, supersession: supersession, now: store.now)
            .activations.map(\.assignment)
    }
    private var nextEnd: Date? { activations.compactMap(\.endAt).min() }

    var body: some View {
        label(at: store.now)
            .task {
                if !accounts.settings.onboardingCompleted {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    @ViewBuilder private func label(at now: Date) -> some View {
        let style = accounts.settings.menuBarStyle
        if activations.isEmpty || style == .icon {
            Image(systemName: activations.isEmpty ? "key.fill" : "key.horizontal.fill")
                .accessibilityLabel(activations.isEmpty ? "AzPim, no active role" : "AzPim, \(activations.count) active")
        } else {
            let remaining = nextEnd.map { $0.timeIntervalSince(now) }
            HStack(spacing: 3) {
                Image(systemName: "key.horizontal.fill")
                Text(text(count: activations.count, remaining: style == .iconCountTime ? remaining : nil))
                    .monospacedDigit()
            }
            .foregroundStyle(Countdown.color(remaining))
            .accessibilityLabel("AzPim, \(activations.count) active, next expiry in \(Countdown.spoken(remaining))")
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
    @AppStorage(PreferenceKeys.panelShowFavorites) private var showFavorites = true

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
            Task { await store.refreshIfStale() }
        })
    }

    private var content: some View {
        let model = model
        return VStack(spacing: 8) {
            heroCard(model)
            errorBanners
            ActiveRolesCard(model: model, emptyText: accountList.isEmpty ? "Add an account to see your roles" : "No active role",
                            showAccount: shownAccounts.count > 1)
            if !favorites.isEmpty { favoritesCard }
            EligibleRolesCard(model: model, accounts: shownAccounts, pendingRecords: pendingRecords,
                              noAccount: accountList.isEmpty, noEligibleText: noEligibleText) { activating = $0 }
            PanelActionList()
        }
        .padding(10)
    }

    // MARK: Hero

    /// The activation that expires first, with its fraction of time left.
    private func nextActivation(_ activations: [ActiveAssignment]) -> NextActivation? {
        guard let next = activations.filter({ ($0.endAt ?? .distantPast) > store.now }).min(by: {
            ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture)
        }), let end = next.endAt else { return nil }
        let remaining = end.timeIntervalSince(store.now)
        let total = max(1, end.timeIntervalSince(next.startAt))
        return NextActivation(assignment: next, remaining: remaining, fraction: remaining / total)
    }

    private func heroCard(_ model: PanelModel) -> some View {
        let activations = model.activations.map(\.assignment)
        let nextActivation = nextActivation(activations)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(activations.count)")
                            .font(.display(52))
                            .monospacedDigit()
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                        Text("active")
                            .font(.display(18, weight: .semibold))
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: activations.isEmpty ? "key.fill" : "key.horizontal.fill")
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                        Text(heroSubtitle(nextActivation, activations))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let next = nextActivation {
                        SectionLabel(text: "Expires in")
                        Text(Countdown.hero(next.remaining))
                            .font(.display(20, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(next.remaining <= 900 ? Theme.remaining(next.remaining) : Color.primary)
                    } else {
                        SectionLabel(text: "Permanent")
                        Text("\(model.permanents.count)").font(.display(20, weight: .semibold)).monospacedDigit()
                    }
                    statusLine
                }
            }
            if let next = nextActivation {
                ProgressTrack(fraction: next.fraction, tint: Theme.remaining(next.remaining))
            }
            if activeAccounts.count > 1 { accountPicker }
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func heroSubtitle(_ nextActivation: NextActivation?, _ activations: [ActiveAssignment]) -> String {
        if accountList.isEmpty { return "Not signed in" }
        if let next = nextActivation { return "\(next.assignment.roleName) · \(next.assignment.scopeName)" }
        return activations.isEmpty ? "No PIM activation" : "PIM roles active"
    }

    @ViewBuilder private var statusLine: some View {
        if store.isRefreshing {
            ProgressView().controlSize(.small)
        } else if store.isOffline {
            Label(offlineText, systemImage: "wifi.slash").font(.system(size: 11)).foregroundStyle(Theme.warning)
                .help("Actions are disabled until the network is back")
        } else if let last = store.lastRefresh {
            Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var accountPicker: some View {
        @Bindable var store = store
        return Picker("Account", selection: $store.accountFilter) {
            Text("All accounts (\(activeAccounts.count))").tag(UUID?.none)
            ForEach(activeAccounts) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    private var offlineText: String {
        guard let last = store.lastOnline else { return "Offline" }
        return "Offline — data from \(last.formatted(date: .omitted, time: .shortened))"
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

private struct NextActivation {
    let assignment: ActiveAssignment
    let remaining: TimeInterval
    let fraction: Double
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
