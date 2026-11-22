import AppKit
import AzPimCore
import SwiftData
import SwiftUI

/// One row of the palette: an eligible role (Return activates) or a timed activation (Return extends, ⌫ deactivates).
struct PaletteRow: Identifiable {
    let entry: PaletteEntry
    let role: EligibleRole?
    let assignment: ActiveAssignment?
    var id: String { entry.id }

    static func rows(_ model: PanelModel) -> [PaletteRow] {
        let active = model.activations.map { row -> PaletteRow in
            let item = row.assignment
            let entry = PaletteEntry(id: item.id, kind: .active, name: item.roleName, scope: item.scopeName,
                                     types: types(item.source), tenant: item.account?.tenantName ?? "")
            return PaletteRow(entry: entry, role: item.eligibleRole, assignment: item)
        }
        let eligible = model.eligible.map { role in
            let entry = PaletteEntry(id: role.id, kind: .eligible, name: role.roleName, scope: role.scopeName,
                                     types: types(role.source), tenant: role.account?.tenantName ?? "")
            return PaletteRow(entry: entry, role: role, assignment: nil)
        }
        return active + eligible
    }

    /// « Entra », « Entra roles »: the names the search matches, as in the panel.
    private static func types(_ source: RoleSource) -> [String] {
        [TypeTag.text(source), PanelRoleType.allCases.first { $0.source == source }?.title ?? ""]
    }
}

/// Quick-activate palette (1.0 item 3), opened by the global shortcut: search, ↑/↓, Return activates the selected
/// role with its default duration (or extends an active one), ⌘Return or Tab opens the Activation Sheet, ⌫ asks to
/// deactivate an active role, Escape closes.
struct QuickPaletteView: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" || $0.statusRaw == "sent" })
    private var pendingRecords: [ActivationRecord]
    @State private var query: String
    @State private var selection: Int?
    @State private var sheetRole: EligibleRole?
    /// Active row waiting for Return (deactivate) or Escape (keep).
    @State private var confirming: String?
    @State private var message: String?
    @FocusState private var searchFocused: Bool
    let close: () -> Void

    static let width: CGFloat = 560
    static let listHeight: CGFloat = 330

    /// `initialQuery`, `initialSelection`: snapshots only.
    init(initialQuery: String = "", initialSelection: Int? = 0, close: @escaping () -> Void) {
        _query = State(initialValue: initialQuery)
        _selection = State(initialValue: initialSelection)
        self.close = close
    }

    private var model: PanelModel {
        let supersession = store.supersession(accountList)
        let accounts = accountList.filter { !supersession.isRetired($0.id) }
        return PanelModel(accounts: accounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    private var rows: [PaletteRow] {
        let all = PaletteRow.rows(model)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return QuickPalette.rank(query, all.map(\.entry)).compactMap { byId[$0.id] }
    }

    var body: some View {
        Group {
            if let role = sheetRole {
                ActivationSheet(role: role, close: close)
            } else {
                list(rows)
            }
        }
        .frame(width: Self.width)
        .background(KeyDownMonitor(handler: handle))
    }

    private func list(_ rows: [PaletteRow]) -> some View {
        VStack(spacing: 0) {
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
                        if rows.isEmpty { EmptyLine(text: query.isEmpty ? "No role to show" : "No role matches") }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, selected: index == selection,
                                           pending: row.role.flatMap { model.waiting($0, in: pendingRecords, now: store.now) }?.status)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = index }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(height: Self.listHeight)
                .onChange(of: selection) { _, index in
                    if let index, rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
                }
            }
            Divider()
            footer(rows)
                .padding(.horizontal, 16)
                .frame(height: 34)
        }
        .onChange(of: query) { selection = rows.isEmpty ? nil : 0 }
        .onAppear { searchFocused = true }
    }

    private func selected(_ rows: [PaletteRow]) -> PaletteRow? {
        selection.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    @ViewBuilder private func footer(_ rows: [PaletteRow]) -> some View {
        HStack(spacing: 12) {
            if let id = confirming, let row = rows.first(where: { $0.id == id }) {
                Text("Deactivate \(row.entry.name)? ↩ Deactivate · esc Keep").foregroundStyle(Theme.danger)
            } else if let message {
                Text(message).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            } else if let row = selected(rows) {
                Text(hints(row)).foregroundStyle(.secondary)
            } else {
                Text("↑↓ Select · esc Close").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
    }

    private func hints(_ row: PaletteRow) -> String {
        guard let role = row.role else { return "esc Close" }
        if row.entry.kind == .active { return "↩ Extend · ⌫ Deactivate · esc Close" }
        let needsSheet = role.policyFetchedAt == nil || role.requiresJustification || role.requiresTicket
        let duration = ISODuration.label(TimeInterval(store.defaultDurationMinutes(for: role) * 60))
        let primary = needsSheet ? "↩ Activate… (\(role.requiresTicket ? "ticket" : "justification") needed)"
            : "↩ Activate for \(duration)"
        return primary + " · ⌘↩ Options · esc Close"
    }

    // MARK: Keys

    private func handle(_ key: PaletteKey) -> Bool {
        guard sheetRole == nil else { return false }   // the sheet's own fields and buttons
        let rows = rows
        if let id = confirming {
            // Return deactivates, Escape keeps the role; any other key drops the question and acts as usual.
            confirming = nil
            if key == .returnKey, let assignment = rows.first(where: { $0.id == id })?.assignment { deactivate(assignment) }
            if key == .returnKey || key == .escape { return true }
        }
        let row = selected(rows)
        let command = PaletteCommand.forKey(key, kind: row?.entry.kind, queryEmpty: query.isEmpty, escapeCloses: true)
        guard command != .pass else { return false }
        perform(command, row: row, count: rows.count)
        return true
    }

    private func perform(_ command: PaletteCommand, row: PaletteRow?, count: Int) {
        switch command {
        case .moveUp: selection = QuickPalette.move(selection, by: -1, count: count)
        case .moveDown: selection = QuickPalette.move(selection, by: 1, count: count)
        case .activate: if let role = row?.role { activate(role) }
        case .extend: extend(row)
        case .openSheet: sheetRole = row?.role
        case .confirmDeactivate: if let assignment = row?.assignment { askToDeactivate(assignment) }
        case .close: close()
        case .pass: break
        }
    }

    private func activate(_ role: EligibleRole) {
        message = "Activating \(role.roleName)…"
        Task {
            switch await store.quickActivate(role) {
            case .needsSheet: sheetRole = role
            case .sent(let status?):
                message = status == .provisioned ? "\(role.roleName) is active." : "\(role.roleName): request sent."
                close()
            case .sent(nil): message = store.rowErrors[role.id] ?? "Activation failed."
            case .blocked(let reason): message = reason
            }
        }
    }

    private func extend(_ row: PaletteRow?) {
        guard let role = row?.role else {
            message = "This activation has no eligibility to extend."
            return
        }
        message = "Extending \(role.roleName)…"
        Task { message = await store.extend(eligibleRoleId: role.id) }
    }

    private func askToDeactivate(_ assignment: ActiveAssignment) {
        // Azure refuses deactivation within 5 minutes of activation (as the row's button).
        if Date.now.timeIntervalSince(assignment.startAt) < 300 {
            message = "Can't deactivate within 5 minutes of activation."
        } else if store.isOffline {
            message = ActivationBlock.offline.message
        } else {
            confirming = assignment.id
        }
    }

    private func deactivate(_ assignment: ActiveAssignment) {
        let name = assignment.roleName, id = assignment.id
        message = "Deactivating \(name)…"
        Task {
            let done = await store.deactivate(assignment)
            message = done ? "\(name) deactivated." : (store.rowErrors[id] ?? "Deactivation failed.")
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var trailing: some View {
        let busy = row.assignment.map(store.isBusy) ?? row.role.map { store.busy.contains($0.id) } ?? false
        if busy {
            ProgressView().controlSize(.small)
        } else if let end = row.assignment?.endAt {
            let remaining = end.timeIntervalSince(store.now)
            Text(Countdown.hero(remaining))
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

/// Opens and closes the palette. Each open builds a fresh view (empty search, first row selected).
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
        panel.contentView = nil
    }

    /// A click in another app or window closes it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
