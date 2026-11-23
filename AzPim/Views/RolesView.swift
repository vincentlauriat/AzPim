import AzPimCore
import SwiftData
import SwiftUI

/// Roles Window (AppFlow, T4.6): every eligible and active role of every account, searchable, with a detail pane.
struct RolesView: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    @Query(sort: \ActiveAssignment.roleName) private var assignments: [ActiveAssignment]
    @State private var search = ""
    @State private var source: RoleSource?
    @State private var accountId: UUID?
    @State private var state: StateFilter = .all
    @State private var selection: RoleRow.ID?

    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All", eligible = "Eligible", active = "Active", permanent = "Permanent"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .eligible: String(localized: "Eligible")
            case .active: String(localized: "Active")
            case .permanent: String(localized: "Permanent")
            }
        }
    }

    /// Accounts in use: an Azure CLI account replaced by a Microsoft sign-in of the same identity is left out.
    private var activeAccounts: [Account] {
        let supersession = store.supersession(accounts)
        return accounts.filter { !supersession.isRetired($0.id) }
    }
    /// Eligible roles of the accounts in use, without superseded ones.
    private var activeRoles: [EligibleRole] {
        let supersession = store.supersession(accounts)
        return roles.filter { role in role.account.map { !supersession.hides($0.id, role.source) } == true }
    }
    /// Live assignments of the accounts in use, without superseded ones.
    private var liveAssignments: [ActiveAssignment] {
        let supersession = store.supersession(accounts)
        return assignments.filter { row in
            row.isLive(at: store.now) && row.account.map { !supersession.hides($0.id, row.source) } == true
        }
    }

    private var rows: [RoleRow] {
        let live = liveAssignments
        let permanentKeys = Set(live.filter { $0.assignmentType == .assigned }.map(\.facts.key))
        var list = activeRoles.map { role in
            RoleRow(role: role, assignment: live.first { $0.eligibleRole?.id == role.id && $0.assignmentType == .activated },
                    heldPermanently: permanentKeys.contains(role.heldKey))
        }
        // One row per permanent role. One also held as an activation is shown by that activation's eligible row
        // ("also permanent"), when that row is listed; otherwise it keeps its own permanent row.
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(activeRoles.map(\.id))
        list += RoleMerge.merge(live.map(\.facts)).compactMap { group -> ActiveAssignment? in
            guard group.type == .activated else { return byId[group.primaryId] }
            guard group.alsoPermanent else { return nil }
            if let role = byId[group.primaryId]?.eligibleRole, listed.contains(role.id) { return nil }
            return group.memberIds.compactMap { byId[$0] }.first { $0.assignmentType == .assigned }
        }.map { RoleRow(permanent: $0) }
        return list.filter { row in
            (source == nil || row.source == source)
                && (accountId == nil || row.account?.id == accountId)
                && state.matches(row)
                && (search.isEmpty || row.searchText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            statStrip
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            split
        }
        .searchable(text: $search, prompt: "Search roles and scopes")
        .toolbar { toolbarItems }
        .navigationTitle("Roles")
        .onChange(of: store.focusedRoleId, initial: true) { _, id in
            guard let id else { return }
            // Clear the filters so the row is visible, then select it.
            search = ""
            source = nil
            accountId = nil
            state = .all
            selection = id
            store.focusedRoleId = nil
        }
    }

    /// Juicy-style KPI tiles: what is active right now, what can be activated.
    private var statStrip: some View {
        let merged = RoleMerge.merge(liveAssignments.map(\.facts))
        let activated = liveAssignments.filter { $0.assignmentType == .activated }
        let permanent = merged.filter { $0.type == .assigned }
        let next = activated.compactMap(\.endAt).min()
        return HStack(spacing: 10) {
            StatTile(label: String(localized: "Active PIM"), value: "\(activated.count)",
                     note: next.map { String(localized: "Next expiry in \(Countdown.full($0.timeIntervalSince(store.now)))") }
                        ?? String(localized: "No activation"),
                     tint: activated.isEmpty ? .secondary : Theme.active, icon: "bolt.fill")
            StatTile(label: String(localized: "tile.permanent", defaultValue: "Permanent"), value: "\(permanent.count)",
                     note: String(localized: "Managed by your administrator"), icon: "lock.fill")
            StatTile(label: String(localized: "tile.eligible", defaultValue: "Eligible"), value: "\(activeRoles.count)",
                     note: String(localized: "Activatable through PIM"), tint: Theme.accent, icon: "key.horizontal.fill")
            StatTile(label: String(localized: "Accounts"), value: "\(activeAccounts.count)",
                     note: activeAccounts.first.map { $0.tenantName ?? $0.upn } ?? String(localized: "None"),
                     icon: "person.crop.circle")
        }
    }

    private var split: some View {
        HSplitView {
            Table(rows, selection: $selection) {
                // The role name gets the room; a long scope is cut in the middle instead.
                TableColumn("Role") { row in
                    Label(row.displayRoleName, systemImage: SourceIcon.name(row.source)).lineLimit(1)
                }
                .width(min: 170, ideal: 230)
                TableColumn("Scope") { row in Text(row.displayScopeName).lineLimit(1).truncationMode(.middle) }
                    .width(min: 90, ideal: 140)
                TableColumn("State") { row in StateBadge(row: row, now: store.now) }
                    .width(min: 90, ideal: 210)
                // Always present: conditional table columns need macOS 14.4.
                TableColumn("Account") { row in Text(row.account?.tenantName ?? row.account?.upn ?? "") }
                    .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: RoleRow.ID.self) { ids in
                if let id = ids.first, let role = rows.first(where: { $0.id == id })?.role {
                    AddToFavoriteMenu(role: role)
                }
            }
            .frame(minWidth: 420)

            Group {
                if let row = rows.first(where: { $0.id == selection }) {
                    RoleDetail(row: row)
                } else {
                    ContentUnavailableView(activeRoles.isEmpty ? emptyTitle : String(localized: "Select a role"),
                                           systemImage: "key.horizontal",
                                           description: Text(accounts.isEmpty ? String(localized: "Add an account to get started.") : ""))
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
        }
    }

    /// No eligible role at all: say why (error, first load) before claiming there is none.
    private var emptyTitle: String {
        if accounts.isEmpty { return String(localized: "No account") }
        if store.refreshErrors.values.contains(where: { !$0.isEmpty }) { return String(localized: "Eligible roles couldn't be loaded") }
        if accounts.allSatisfy({ $0.lastRefreshAt == nil }) { return String(localized: "Loading eligible roles…") }
        return String(localized: "No eligible role")
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Source", selection: $source) {
                Text("All sources").tag(RoleSource?.none)
                Text("Azure resources").tag(RoleSource?.some(.azureResource))
                Text("Entra roles").tag(RoleSource?.some(.entraRole))
                Text("PIM groups").tag(RoleSource?.some(.pimGroup))
            }
            Picker("State", selection: $state) {
                ForEach(StateFilter.allCases) { Text($0.title).tag($0) }
            }
            if activeAccounts.count > 1 {
                Picker("Account", selection: $accountId) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(activeAccounts) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
                }
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
    }
}

/// One line of the Roles table: an eligible role (maybe active) or a permanent assignment.
struct RoleRow: Identifiable {
    let id: String
    let role: EligibleRole?
    let assignment: ActiveAssignment?
    /// An eligible role also assigned permanently: it is held even without an activation.
    let heldPermanently: Bool

    init(role: EligibleRole, assignment: ActiveAssignment?, heldPermanently: Bool = false) {
        id = role.id
        self.role = role
        self.assignment = assignment
        self.heldPermanently = heldPermanently
    }

    init(permanent: ActiveAssignment) {
        id = permanent.id
        role = nil
        assignment = permanent
        heldPermanently = true
    }

    var source: RoleSource { role?.source ?? assignment?.source ?? .azureResource }
    var roleName: String { role?.roleName ?? assignment?.roleName ?? "" }
    var scopeName: String { role?.scopeName ?? assignment?.scopeName ?? "" }
    var scope: String { role?.scope ?? assignment?.scope ?? "" }
    var account: Account? { role?.account ?? assignment?.account }
    var isPermanent: Bool { role == nil }
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
    /// Raw and displayed names, so « Owner » and « Propriétaire » both match.
    var searchText: String { "\(roleName) \(scopeName) \(displayRoleName) \(displayScopeName) \(account?.upn ?? "")" }
}

extension RolesView.StateFilter {
    func matches(_ row: RoleRow) -> Bool {
        switch self {
        case .all: true
        case .eligible: !row.isPermanent && row.assignment == nil && !row.heldPermanently
        case .active: !row.isPermanent && (row.assignment != nil || row.heldPermanently)
        case .permanent: row.isPermanent
        }
    }
}

private struct StateBadge: View {
    let row: RoleRow
    let now: Date

    var body: some View {
        if row.isPermanent {
            Text("Permanent").foregroundStyle(.secondary)
        } else if let end = row.assignment?.endAt {
            let left = Countdown.long(end.timeIntervalSince(now))
            Text(row.heldPermanently ? String(localized: "\(left) · also permanent") : left)
                .foregroundStyle(Theme.active).monospacedDigit()
                .accessibilityLabel(String(localized: "\(Countdown.spoken(end.timeIntervalSince(now))) left"))
        } else if row.heldPermanently {
            Text("Active · permanent").foregroundStyle(Theme.active)
                .help("Also assigned permanently: already held without an activation")
        } else {
            Text("Eligible").foregroundStyle(.secondary)
        }
    }
}

private struct RoleDetail: View {
    @Environment(RoleStore.self) private var store
    let row: RoleRow
    @State private var activating = false
    @State private var confirmingDeactivate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: SourceIcon.name(row.source))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(row.assignment != nil ? Theme.active : Theme.accent)
                        Text(row.displayRoleName).font(.display(22, weight: .semibold))
                    }
                    Text(row.displayScopeName).foregroundStyle(.secondary)
                    StateBadge(row: row, now: store.now)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    detail("Source", sourceName(row.source))
                    detail("Account", row.account?.upn ?? "—")
                    if let role = row.role {
                        detail("Assignment", memberName(role.memberType))
                    }
                    detail("Scope path", row.scope)
                    if let end = row.assignment?.endAt {
                        detail("Ends", end.appFormatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                if let role = row.role {
                    policy(role)
                    actions(role)
                } else {
                    Text("Permanent assignment: managed by your administrator, not through PIM.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = store.rowErrors[row.id] ?? row.assignment.flatMap({ store.rowErrors[$0.id] }) {
                    Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
                if let result = store.lastResult, result.roleId != nil, result.roleId == row.role?.id,
                   result.isRecent(at: store.now) {
                    ResultStatusLine(result: result)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: row.id) {
            if let role = row.role { await store.ensurePolicy(for: role) }
        }
        .sheet(isPresented: $activating) {
            if let role = row.role {
                ActivationSheet(role: role, fromPanel: false) { activating = false }.frame(width: 360)
            }
        }
    }

    @ViewBuilder private func policy(_ role: EligibleRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: String(localized: "Policy"))
            if role.policyFetchedAt == nil {
                Text("Policy unavailable").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    detail("Maximum", role.maxDuration.flatMap(ISODuration.seconds).map { ISODuration.label($0) } ?? "—")
                    let required = String(localized: "Required"), notRequired = String(localized: "No")
                    detail("Justification", role.requiresJustification ? required : String(localized: "Optional"))
                    detail("Ticket", role.requiresTicket ? required : notRequired)
                    detail("MFA", role.requiresMFA ? required : notRequired)
                    detail("Approval", role.requiresApproval ? required : notRequired)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private func actions(_ role: EligibleRole) -> some View {
        let block = row.assignment == nil ? activateBlock(role) : nil
        HStack {
            if store.busy.contains(role.id) || row.assignment.map(store.isBusy) == true {
                ProgressView().controlSize(.small)
            } else if let assignment = row.assignment {
                Button("Deactivate", role: .destructive) { confirmingDeactivate = true }
                    .disabled(Date.now.timeIntervalSince(assignment.startAt) < 300 || store.isOffline)
                    .help("Azure refuses deactivation within 5 minutes of activation")
                    .confirmationDialog("Deactivate \(assignment.displayRoleName)?", isPresented: $confirmingDeactivate) {
                        Button("Deactivate", role: .destructive) { Task { await store.deactivate(assignment) } }
                    } message: {
                        Text(assignment.displayScopeName)
                    }
            } else {
                Button("Activate…") { activating = true }.buttonStyle(.borderedProminent).tint(Theme.accentFill)
                    .disabled(block != nil)
            }
            Menu("Add to favorite") { AddToFavoriteMenu(role: role) }.fixedSize()
        }
        // Why Activate… cannot be pressed (the form itself is checked in the sheet).
        if !store.busy.contains(role.id), let block {
            Text(block.message).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Read once per body; `store.now` follows the store clock (a sent request's 15-minute window).
    private func activateBlock(_ role: EligibleRole) -> ActivationBlock? {
        // Duration and form are the sheet's: only the state is checked here.
        ActivationBlock.reason(.init(inProgress: store.busy.contains(role.id),
                                     pending: store.waitingRequest(for: role, at: store.now) != nil,
                                     offline: store.isOffline, minutes: ActivationDuration.minMinutes(policyMax: role.maxDuration),
                                     policyMax: role.maxDuration, requiresJustification: false))
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }

    private func sourceName(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: String(localized: "Azure resource")
        case .entraRole: String(localized: "Entra role")
        case .pimGroup: String(localized: "PIM group")
        }
    }

    private func memberName(_ type: MemberType) -> String {
        switch type {
        case .direct: String(localized: "Direct")
        case .group: String(localized: "Via group")
        case .inherited: String(localized: "Inherited")
        }
    }
}
