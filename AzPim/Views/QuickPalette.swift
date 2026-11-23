import AppKit
import AzPimCore
import SwiftData
import SwiftUI

/// One row of the palette: an eligible role (Return activates) or a timed activation (⇧Return extends, ⌫ deactivates).
struct PaletteRow: Identifiable {
    let entry: PaletteEntry
    let role: EligibleRole?
    let assignment: ActiveAssignment?
    var id: String { entry.id }

    /// Eligible roles first (Return activates them), then the activations.
    static func rows(_ model: PanelModel) -> [PaletteRow] {
        let eligible = model.eligible.map { role in
            let entry = PaletteEntry(id: role.id, kind: .eligible, name: role.displayRoleName, scope: role.displayScopeName,
                                     types: types(role.source) + [role.roleName, role.scopeName],
                                     tenant: role.account?.tenantName ?? "")
            return PaletteRow(entry: entry, role: role, assignment: nil)
        }
        let active = model.activations.map { row -> PaletteRow in
            let item = row.assignment
            let entry = PaletteEntry(id: item.id, kind: .active, name: item.displayRoleName, scope: item.displayScopeName,
                                     types: types(item.source) + [item.roleName, item.scopeName],
                                     tenant: item.account?.tenantName ?? "")
            return PaletteRow(entry: entry, role: item.eligibleRole, assignment: item)
        }
        return eligible + active
    }

    /// « Entra », « Entra roles »: the names the search matches, as in the panel; the raw role and scope names
    /// (« Owner », « Directory ») are added beside the displayed ones.
    private static func types(_ source: RoleSource) -> [String] {
        [TypeTag.text(source), PanelRoleType.allCases.first { $0.source == source }?.title ?? ""]
    }
}

/// Quick-activate palette (1.0 item 3), opened by the global shortcut: search, ↑/↓, Return activates the selected
/// eligible role with its default duration, ⌘Return or Tab opens the Activation Sheet, ⇧Return extends an active
/// role and ⌫ asks to deactivate it (Return does nothing on an active row), Escape closes.
struct QuickPaletteView: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent" })
    private var pendingRecords: [ActivationRecord]
    @State private var query: String
    /// Selection (by row id), Deactivate question and status line.
    @State private var session = PaletteSession()
    @State private var sheetRole: EligibleRole?
    @FocusState private var searchFocused: Bool
    /// Snapshots: the row index to select once the rows are known.
    private let initialSelection: Int?
    let close: () -> Void

    static let width: CGFloat = 560
    static let listHeight: CGFloat = 330

    /// `initialQuery`, `initialSelection`: snapshots only.
    init(initialQuery: String = "", initialSelection: Int? = nil, close: @escaping () -> Void) {
        _query = State(initialValue: initialQuery)
        self.initialSelection = initialSelection
        self.close = close
    }

    private func makeModel() -> PanelModel {
        let supersession = store.supersession(accountList)
        let accounts = accountList.filter { !supersession.isRetired($0.id) }
        return PanelModel(accounts: accounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    private func makeRows(_ model: PanelModel) -> [PaletteRow] {
        let all = PaletteRow.rows(model)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return QuickPalette.rank(query, all.map(\.entry)).compactMap { byId[$0.id] }
    }

    var body: some View {
        Group {
            if let role = sheetRole {
                ActivationSheet(role: role, fromPanel: false, close: close)
            } else {
                // Built once per body: the store clock ticks every second near an expiry.
                let model = makeModel()
                list(model, rows: makeRows(model))
            }
        }
        .frame(width: Self.width)
        .background(KeyDownMonitor(handler: handle, onKeyUp: { session.keyUp() }))
    }

    private func list(_ model: PanelModel, rows: [PaletteRow]) -> some View {
        let selectedIndex = session.index(in: rows.map(\.id))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(Theme.accent)
                TextField("Activate a role", text: $query, prompt: Text("Activate a role…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
                    .accessibilityLabel("Search roles to activate")
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        if rows.isEmpty {
                            EmptyLine(text: query.isEmpty ? String(localized: "No role to show") : String(localized: "No role matches"))
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, selected: index == selectedIndex,
                                           pending: row.role.flatMap { model.waiting($0, in: pendingRecords, now: store.now) }?.status)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { session.select(row.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(height: Self.listHeight)
                .onChange(of: session.selectedId) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            footer(selectedIndex.map { rows[$0] }, rows: rows)
                .padding(.horizontal, 16)
                .frame(height: 34)
        }
        .onChange(of: query) { session.queryChanged(query, firstId: makeRows(makeModel()).first?.id) }
        .announcesChanges(session.message)
        .onAppear {
            searchFocused = true
            if let initialSelection, rows.indices.contains(initialSelection) { session.select(rows[initialSelection].id) }
        }
    }

    @ViewBuilder private func footer(_ selected: PaletteRow?, rows: [PaletteRow]) -> some View {
        HStack(spacing: 12) {
            if let id = session.confirming, let row = rows.first(where: { $0.id == id }) {
                Text("Deactivate \(row.entry.name)? ↩ Deactivate · esc Keep").foregroundStyle(Theme.danger)
            } else if let message = session.message {
                Text(message).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            } else if let selected {
                Text(hints(selected)).foregroundStyle(.secondary)
            } else {
                Text("↑↓ Select · esc Close").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
    }

    private func hints(_ row: PaletteRow) -> String {
        let close = String(localized: "esc Close")
        if row.entry.kind == .active { return PaletteCommand.alreadyActiveHint + " · " + close }
        guard let role = row.role else { return close }
        let needsSheet = role.policyFetchedAt == nil || role.requiresJustification || role.requiresTicket
        let duration = ISODuration.label(TimeInterval(store.defaultDurationMinutes(for: role) * 60))
        let primary = !needsSheet ? String(localized: "↩ Activate for \(duration)")
            : role.requiresTicket ? String(localized: "↩ Activate… (ticket needed)")
            : String(localized: "↩ Activate… (justification needed)")
        return primary + " · " + String(localized: "⌘↩ Options") + " · " + close
    }

    // MARK: Keys

    private func handle(_ key: PaletteKey, isRepeat: Bool) -> Bool {
        guard sheetRole == nil else { return false }   // the sheet's own fields and buttons
        // The key that confirmed a deactivation is still down: no second action from it.
        guard session.allows(key) else { return true }
        let rows = makeRows(makeModel())
        switch session.answer(key, isRepeat: isRepeat) {
        case .deactivate(let id):
            if let assignment = rows.first(where: { $0.id == id })?.assignment { deactivate(assignment) }
            return true
        case .keep, .ignored: return true
        case .none, .dropped: break
        }
        let ids = rows.map(\.id)
        let row = session.index(in: ids).map { rows[$0] }
        let command = PaletteCommand.forKey(key, kind: row?.entry.kind, isRepeat: isRepeat, queryEmpty: query.isEmpty,
                                            escapeCloses: true)
        guard command != .pass else { return false }
        perform(command, row: row, ids: ids)
        return true
    }

    private func perform(_ command: PaletteCommand, row: PaletteRow?, ids: [String]) {
        switch command {
        case .moveUp, .moveDown: session.move(by: command == .moveUp ? -1 : 1, in: ids)
        case .activate: if let role = row?.role { activate(role) }
        case .alreadyActive: session.message = PaletteCommand.alreadyActiveHint
        case .extend: extend(row)
        case .openSheet: sheetRole = row?.role
        case .confirmDeactivate: if let assignment = row?.assignment { askToDeactivate(assignment) }
        case .close: close()
        case .ignore, .pass: break
        }
    }

    private func activate(_ role: EligibleRole) {
        session.message = String(localized: "Activating \(role.displayRoleName)…")
        Task {
            switch await store.quickActivate(role, fromPanel: false) {
            case .needsSheet: sheetRole = role
            case .sent(_?): close()
            case .sent(nil): session.message = store.rowErrors[role.id] ?? String(localized: "Activation failed.")
            case .blocked(let reason): session.message = reason
            }
        }
    }

    private func extend(_ row: PaletteRow?) {
        guard let role = row?.role else {
            session.message = String(localized: "This activation has no eligibility to extend.")
            return
        }
        session.message = String(localized: "Extending \(role.displayRoleName)…")
        Task { session.message = await store.extend(eligibleRoleId: role.id) }
    }

    private func askToDeactivate(_ assignment: ActiveAssignment) {
        // Azure refuses deactivation within 5 minutes of activation (as the row's button).
        if Date.now.timeIntervalSince(assignment.startAt) < 300 {
            session.message = String(localized: "Can't deactivate within 5 minutes of activation.")
        } else if store.isOffline {
            session.message = ActivationBlock.offline.message
        } else {
            session.ask(assignment.id)
        }
    }

    private func deactivate(_ assignment: ActiveAssignment) {
        let name = assignment.displayRoleName, id = assignment.id
        session.message = String(localized: "Deactivating \(name)…")
        Task {
            let done = await store.deactivate(assignment)
            session.message = done ? String(localized: "\(name) deactivated.")
                : (store.rowErrors[id] ?? String(localized: "Deactivation failed."))
        }
    }
}

private struct PaletteRowView: View {
    @Environment(RoleStore.self) private var store
    let row: PaletteRow
    let selected: Bool
    let pending: RequestStatus?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SourceIcon.name(row.assignment?.source ?? row.role?.source ?? .azureResource))
                .frame(width: 22)
                .foregroundStyle(row.entry.kind == .active ? Theme.active : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.entry.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(([row.entry.scope, row.entry.types.first ?? ""] + (row.entry.tenant.isEmpty ? [] : [row.entry.tenant]))
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.vertical, 5)
        .frame(minHeight: 40)
        .keyboardSelected(selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpokenRole.label(role: row.entry.name, source: source, scope: row.entry.scope,
                                             state: spokenState, account: row.entry.tenant))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(row.assignment?.endAt != nil ? .updatesFrequently : [])
    }

    private var source: RoleSource { row.assignment?.source ?? row.role?.source ?? .azureResource }

    private var spokenState: SpokenRoleState {
        if row.assignment.map({ store.isBusy($0) }) ?? row.role.map({ store.busy.contains($0.id) }) ?? false { return .busy }
        if let assignment = row.assignment { return .active(remaining: assignment.endAt?.timeIntervalSince(store.now)) }
        switch pending {
        case .sent?: return .sent
        case .some: return .pendingApproval
        case nil: return .eligible
        }
    }

    @ViewBuilder private var trailing: some View {
        let busy = row.assignment.map { store.isBusy($0) } ?? row.role.map { store.busy.contains($0.id) } ?? false
        if busy {
            ProgressView().controlSize(.small)
        } else if let end = row.assignment?.endAt {
            let remaining = end.timeIntervalSince(store.now)
            Text(Countdown.compact(remaining))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.remaining(remaining))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.remaining(remaining).opacity(0.14), in: Capsule())
        } else if let pending {
            Label(pending == .sent ? "Sent" : "Pending", systemImage: "clock")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
        } else if selected {
            Text("↩").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Window

/// A panel that takes the keyboard without activating AzPim: the app the user was in stays frontmost.
final class QuickPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opens and closes the palette. Each open builds a fresh view (empty search, no row selected until ↓).
@MainActor
final class QuickPaletteController: NSObject, NSWindowDelegate {
    private let container: ModelContainer
    private let accounts: AccountService
    private let store: RoleStore
    private var panel: QuickPalettePanel?

    init(container: ModelContainer, accounts: AccountService, store: RoleStore) {
        self.container = container
        self.accounts = accounts
        self.store = store
    }

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    func show() {
        let panel = QuickPalettePanel(contentRect: NSRect(x: 0, y: 0, width: QuickPaletteView.width, height: 420),
                                      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        let root = QuickPaletteView { [weak self] in self?.close() }
            .environment(accounts)
            .environment(store)
            .modelContainer(container)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        let size = hosting.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            // Spotlight's place: centred, in the upper part of the screen.
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - screen.height * 0.2 - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        store.panelOpenedAt = .now
        Task { await store.refreshIfStale() }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        // Torn down after the current event: `close` is often called from inside the view's own key handler.
        DispatchQueue.main.async { panel.contentView = nil }
    }

    /// A click in another app or window closes it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
