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
            .accessibilityLabel((activations.isEmpty ? String(localized: "AzPim, no active role")
                                 : String(localized: "AzPim, \(activations.count) active")) + pending)
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
            .accessibilityLabel(String(localized: "AzPim, \(activations.count) active, next expiry in \(Countdown.spoken(remaining))")
                                + pending)
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
    @State private var askingFavorite: FavoriteRunRequest?   // grouped favorite sheet: justification, tickets
    @State private var contentHeight: CGFloat = 0
    @State private var query: String
    @FocusState private var searchFocused: Bool
    @AppStorage(PreferenceKeys.panelShowFavorites) private var showFavorites = true
    // Keyboard navigation (1.0 item 3): the row ↑/↓ selected, the one ⌫ asked to deactivate, the last Extend result.
    @State private var selectedRowId: String?
    @State private var confirmDeactivateId: String?
    @State private var keyboardMessage: String?
    // Same keys as the cards: ↑/↓ skip the rows of a collapsed card or group.
    @AppStorage(PreferenceKeys.panelShowActive) private var showActive = true
    @AppStorage(PreferenceKeys.panelShowEligible) private var showEligible = true
    @AppStorage(PreferenceKeys.panelShowEligibleEntra) private var showEntra = true
    @AppStorage(PreferenceKeys.panelShowEligibleAzure) private var showAzure = true
    @AppStorage(PreferenceKeys.panelShowEligibleGroups) private var showGroups = true

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
                ActivationSheet(role: role) { activating = nil }.frame(width: Theme.panelWidth)
            } else if let request = askingFavorite {
                FavoriteActivationSheet(request: request) { askingFavorite = nil }.frame(width: Theme.panelWidth)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        content
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                            })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
                    .frame(width: Theme.panelWidth, height: min(contentHeight > 0 ? contentHeight : 520, maxHeight))
                    .onChange(of: selectedRowId) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: query) { keyboardMessage = nil }
                }
            }
        }
        .background(KeyDownMonitor(handler: handleKey))
        .background(WindowKeyObserver {
            store.panelOpenedAt = .now
            selectedRowId = nil
            confirmDeactivateId = nil
            keyboardMessage = nil
            // Each open starts without a search (snapshots keep theirs).
            #if DEBUG
            if !store.snapshotFrozen { query = "" }
            #else
            query = ""
            #endif
            Task { await store.refreshIfStale() }
        })
    }

    private var content: some View {
        let model = model
        return VStack(spacing: 8) {
            header
            if let keyboardMessage {
                Text(keyboardMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
            heroCard(model)
            errorBanners
            if RoleSearch.isEmpty(query) {
                ActiveRolesCard(model: model,
                                emptyText: accountList.isEmpty ? String(localized: "Add an account to see your roles")
                                    : String(localized: "No active role"),
                                showAccount: shownAccounts.count > 1, selectedId: selectedRowId, confirmId: $confirmDeactivateId)
                if !favorites.isEmpty { favoritesCard }
                EligibleRolesCard(model: model, accounts: shownAccounts, pendingRecords: pendingRecords,
                                  noAccount: accountList.isEmpty, noEligibleText: noEligibleText,
                                  selectedId: selectedRowId) { activateTapped($0) }
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
            EmptyLine(text: String(localized: "No role matches"))
                .padding(.horizontal, 14)
                .card()
        }
        if !found.activations.isEmpty || !found.permanents.isEmpty {
            ActiveRolesCard(model: found, emptyText: "", showAccount: shownAccounts.count > 1, searching: true,
                            selectedId: selectedRowId, confirmId: $confirmDeactivateId)
        }
        if !found.eligible.isEmpty {
            EligibleRolesCard(model: found, accounts: shownAccounts, pendingRecords: pendingRecords, noAccount: false,
                              noEligibleText: noEligibleText, searching: true, selectedId: selectedRowId) { activateTapped($0) }
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
        // No-break spaces: a wrapped hero line never splits « 3 h 24 min ».
        let expiry = next.map { Countdown.full($0.remaining).replacingOccurrences(of: " ", with: "\u{00A0}") }
        let summary = HeroSummary(activeCount: model.activations.count, nextExpiry: expiry,
                                  pendingCount: model.pendingApprovalCount(in: pendingRecords))
        return CompactHeroCard(summary: summary, activeCount: model.activations.count, remaining: next?.remaining,
                               nextRole: next.map { "\($0.assignment.displayRoleName) · \($0.assignment.displayScopeName)" },
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
        DisclosureCard(title: String(localized: "Favorites"), icon: "star.fill", iconColor: Theme.violet,
                       count: favorites.count, expanded: $showFavorites) {
            FavoriteChips(favorites: favorites) { askingFavorite = $0 }
        }
    }
}

extension MenuBarPanel {
    /// "No eligible role" only once a refresh read every source: an error or a first load is not that.
    fileprivate func noEligibleText(_ account: Account) -> String {
        if !(store.refreshErrors[account.id] ?? [:]).isEmpty {
            return String(localized: "Couldn't load the eligible roles of \(account.upn)")
        }
        if account.lastRefreshAt == nil { return String(localized: "Loading the eligible roles of \(account.upn)…") }
        return String(localized: "No eligible PIM role for \(account.upn)")
    }
}

// MARK: - Keyboard (1.0 item 3)

/// A row ↑/↓ can select: a timed activation or an eligible role, in the order the cards show them.
private struct KeyRow {
    let id: String
    let kind: PaletteKind
    let role: EligibleRole?
    let assignment: ActiveAssignment?
}

extension MenuBarPanel {
    /// Visible actionable rows, top to bottom: activations, then eligible roles per tenant and type (collapsed cards
    /// and groups left out, every group open while searching). Permanent rows and favorites have no keyboard action.
    fileprivate func keyRows() -> [KeyRow] {
        let searching = !RoleSearch.isEmpty(query)
        let shown = searching ? model.filtered(by: query) : model
        var rows: [KeyRow] = []
        if searching || showActive {
            rows += shown.activations.map {
                KeyRow(id: $0.id, kind: .active, role: $0.assignment.eligibleRole, assignment: $0.assignment)
            }
        }
        guard searching || showEligible else { return rows }
        let accounts = shownAccounts
        var seen = Set<String>()
        for tenant in accounts.map({ $0.tenantId.lowercased() }) where seen.insert(tenant).inserted {
            let ids = Set(accounts.filter { $0.tenantId.lowercased() == tenant }.map(\.id))
            let roles = shown.eligible.filter { $0.account.map { ids.contains($0.id) } == true }
            for type in PanelRoleType.allCases where searching || isExpanded(type) {
                rows += roles.filter { $0.source == type.source }.map {
                    KeyRow(id: $0.id, kind: .eligible, role: $0, assignment: nil)
                }
            }
        }
        return rows
    }

    private func isExpanded(_ type: PanelRoleType) -> Bool {
        switch type {
        case .entra: showEntra
        case .azure: showAzure
        case .groups: showGroups
        }
    }

    /// ↑/↓ select, Return activates (quick; nothing on an active row), ⇧Return extends, ⌘Return / Tab open the sheet,
    /// ⌫ / ⌘⌫ ask to deactivate once the search is empty. Held action keys never repeat. Escape and ⌘F stay with the
    /// search field and the panel.
    fileprivate func handleKey(_ key: PaletteKey, isRepeat: Bool) -> Bool {
        guard activating == nil, askingFavorite == nil else { return false }   // the sheets' own fields
        guard confirmDeactivateId == nil else { return false }   // the Deactivate popover answers
        let rows = keyRows()
        let index = selectedRowId.flatMap { id in rows.firstIndex { $0.id == id } }
        let row = index.map { rows[$0] }
        let command = PaletteCommand.forKey(key, kind: row?.kind, isRepeat: isRepeat, queryEmpty: query.isEmpty,
                                            escapeCloses: false)
        if command == .moveUp || command == .moveDown {
            selectedRowId = QuickPalette.move(index, by: command == .moveUp ? -1 : 1, count: rows.count).map { rows[$0].id }
            keyboardMessage = nil
            return true
        }
        return perform(command, row: row)
    }

    private func perform(_ command: PaletteCommand, row: KeyRow?) -> Bool {
        switch command {
        case .activate: if let role = row?.role { quickActivate(role) }
        case .alreadyActive: keyboardMessage = PaletteCommand.alreadyActiveHint
        case .extend: if let role = row?.role { extend(role) }
        case .openSheet: activating = row?.role
        case .confirmDeactivate: if let assignment = row?.assignment { askToDeactivate(assignment) }
        case .ignore, .moveUp, .moveDown: break
        case .close, .pass: return false
        }
        return true
    }

    private func extend(_ role: EligibleRole) {
        keyboardMessage = String(localized: "Extending \(role.displayRoleName)…")
        Task { keyboardMessage = await store.extend(eligibleRoleId: role.id) }
    }

    /// Opens the row's own Deactivate question, or says why it cannot (as the row's disabled button).
    private func askToDeactivate(_ assignment: ActiveAssignment) {
        if Date.now.timeIntervalSince(assignment.startAt) < 300 {
            keyboardMessage = String(localized: "Can't deactivate within 5 minutes of activation.")
        } else if store.isOffline {
            keyboardMessage = ActivationBlock.offline.message
        } else {
            confirmDeactivateId = assignment.id
        }
    }

    /// Activate button: the sheet, or with ⌥ held a quick activation (the sheet still opens when the policy needs it).
    fileprivate func activateTapped(_ role: EligibleRole) {
        if NSEvent.modifierFlags.contains(.option) { quickActivate(role) } else { activating = role }
    }

    /// Errors and blocks land on the row (`rowErrors`).
    private func quickActivate(_ role: EligibleRole) {
        Task {
            if await store.quickActivate(role) == .needsSheet { activating = role }
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
