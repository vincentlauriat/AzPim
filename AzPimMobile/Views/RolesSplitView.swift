import AzPimCore
import SwiftData
import SwiftUI

/// Regular width (iPhone Duo unfolded, a Max in landscape): every role, filtered by source, state, account and search,
/// next to the selected role's detail, as the Mac Roles Window. The selection and the filters are `MobileNavigation`'s.
struct RolesSplitView: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    @Query(sort: \ActiveAssignment.roleName) private var assignments: [ActiveAssignment]

    /// Accounts in use: an Azure CLI account replaced by a Microsoft sign-in of the same identity is left out.
    private var activeAccounts: [Account] {
        let supersession = store.supersession(accounts)
        return accounts.filter { !supersession.isRetired($0.id) }
    }

    var body: some View {
        @Bindable var navigation = navigation
        let all = RoleRows.make(roles: roles, assignments: assignments, supersession: store.supersession(accounts), now: store.now)
        let rows = RoleRows.filter(all, source: navigation.source, accountId: navigation.accountId, state: navigation.state,
                                   search: navigation.search)
        NavigationSplitView {
            List(selection: $navigation.selection) {
                StatusSection(accounts: activeAccounts)
                Section {
                    ForEach(rows) { row in RoleListRow(row: row).tag(row.id) }
                } header: {
                    Text("Roles")
                } footer: {
                    if rows.isEmpty { Text(all.isEmpty ? "No eligible role" : "No match") }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $navigation.search, placement: .sidebar, prompt: "Search roles and scopes")
            .refreshable { await store.refresh() }
            .navigationTitle("AzPim")
            .toolbar {
                MobileToolbar()
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
        } detail: {
            NavigationStack {
                if let id = navigation.selection, all.contains(where: { $0.id == id }) {
                    RoleDetailScreen(rowId: id)
                } else {
                    ContentUnavailableView("Select a role", systemImage: "key.horizontal")
                }
            }
        }
    }

    /// Source, state and account pickers in one menu; its label says which filters are on.
    private var filterMenu: some View {
        @Bindable var navigation = navigation
        let filtered = navigation.source != nil || navigation.state != .all || navigation.accountId != nil
        return Menu {
            Picker("Source", selection: $navigation.source) {
                Text("All sources").tag(RoleSource?.none)
                Text("Azure resources").tag(RoleSource?.some(.azureResource))
                Text("Entra roles").tag(RoleSource?.some(.entraRole))
                Text("PIM groups").tag(RoleSource?.some(.pimGroup))
            }
            Picker("State", selection: $navigation.state) {
                ForEach(RoleStateFilter.allCases) { Text($0.title).tag($0) }
            }
            if activeAccounts.count > 1 {
                Picker("Account", selection: $navigation.accountId) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(activeAccounts) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
                }
            }
        } label: {
            Label("Filters", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(filtered ? String(localized: "On") : String(localized: "Off"))
    }
}

/// A line of the roles list: name, type and scope, and the state (time left, eligible, permanent).
private struct RoleListRow: View {
    @Environment(RoleStore.self) private var store
    let row: RoleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoleLabel(name: row.displayRoleName, scope: row.displayScopeName, source: row.source, tenant: nil)
            RoleStateText(row: row, now: store.now).font(.footnote)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The state of a role row, as on the Mac: time left (maybe « also permanent »), active through a permanent
/// assignment, permanent, or eligible.
struct RoleStateText: View {
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
        } else {
            Text("Eligible").foregroundStyle(.secondary)
        }
    }
}
