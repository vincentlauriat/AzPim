import AzPimCore
import SwiftData
import SwiftUI

/// A role's detail, as the Mac Roles Window shows it: state, actions (Activate…, Extend, Deactivate), where it applies,
/// its policy (maximum duration, justification, ticket, MFA, approval) and this role's requests. The detail column in
/// regular width, pushed on top of the panel in compact width. `rowId`: a `RoleRow.id`, resolved on every update so a
/// refresh (activation, deactivation) keeps it shown.
struct RoleDetailScreen: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @ScaledMetric(relativeTo: .title) private var dialSize: CGFloat = 68
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    @Query(sort: \ActiveAssignment.roleName) private var assignments: [ActiveAssignment]
    @Query(sort: \ActivationRecord.sentAt, order: .reverse) private var records: [ActivationRecord]
    let rowId: String

    var body: some View {
        let supersession = store.supersession(accounts)
        if let row = RoleRows.make(roles: roles, assignments: assignments, supersession: supersession, now: store.now)
            .first(where: { $0.id == rowId }) {
            List {
                header(row)
                actions(row)
                details(row)
                if let role = row.role {
                    policy(role)
                    history(role, supersession: supersession)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(row.displayRoleName)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: row.id) {
                if let role = row.role { await store.ensurePolicy(for: role) }
            }
        } else {
            // The row is gone (account signed out, eligibility removed): drop the selection, which pops this page in
            // compact width instead of leaving a "Select a role" page with no list to select from.
            ContentUnavailableView("Select a role", systemImage: "key.horizontal")
                .task(id: rowId) { if navigation.selection == rowId { navigation.selection = nil } }
        }
    }

    // MARK: Sections

    /// The panel's look: the activation's dial, else the source square, next to the name, scope and state; under
    /// them when that does not fit on one line (narrow detail column, long name, large Dynamic Type).
    private func header(_ row: RoleRow) -> some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { headerMark(row); headerText(row).fixedSize() }
                VStack(alignment: .leading, spacing: 10) { headerMark(row); headerText(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func headerMark(_ row: RoleRow) -> some View {
        if let assignment = row.assignment, assignment.endAt != nil {
            ActivationDial(assignment: assignment, size: min(dialSize, 110))
        } else {
            SourceBadge(source: row.source, size: min(dialSize * 0.75, 80))
        }
    }

    private func headerText(_ row: RoleRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.displayRoleName).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(row.displayScopeName).foregroundStyle(.secondary)
            RoleStateText(row: row, now: store.now).font(.headline)
        }
    }

    @ViewBuilder private func actions(_ row: RoleRow) -> some View {
        Section {
            if let role = row.role {
                if store.busy.contains(role.id) || row.assignment.map(store.isBusy) == true {
                    HStack { ProgressView(); Spacer() }
                } else if let assignment = row.assignment {
                    Button { navigation.extend(role, store: store) } label: {
                        Label("Extend", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(store.isOffline)
                    let tooRecent = assignment.isTooRecentToDeactivate(at: store.now)
                    Button(role: .destructive) { navigation.deactivating = assignment } label: {
                        Label("Deactivate…", systemImage: "stop.circle")
                    }
                    .disabled(tooRecent || store.isOffline)
                    if tooRecent {
                        Text("Can't deactivate within 5 minutes of activation.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    let block = role.activateBlock(in: store)
                    Button { navigation.activating = role } label: {
                        Label("Activate…", systemImage: "bolt.fill")
                    }
                    .disabled(block != nil)
                    if let block { Text(block.message).font(.footnote).foregroundStyle(.secondary) }
                }
                if let result = navigation.extendResults[role.id] {
                    Text(result).font(.footnote)
                }
            } else {
                Text("Permanent assignment: managed by your administrator, not through PIM.").foregroundStyle(.secondary)
            }
            if let error = store.rowErrors[row.id] ?? row.assignment.flatMap({ store.rowErrors[$0.id] }) {
                Text(error).font(.footnote).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            if let result = store.lastResult, result.roleId != nil, result.roleId == row.role?.id, result.isRecent(at: store.now) {
                ResultStatusLine(result: result)
            }
        }
    }

    private func details(_ row: RoleRow) -> some View {
        Section("Details") {
            DetailRow(label: "Source", value: sourceName(row.source))
            DetailRow(label: "Account", value: row.account?.upn ?? "—")
            if let role = row.role { DetailRow(label: "Assignment", value: memberName(role.memberType)) }
            DetailRow(label: "Scope path", value: row.scope)
            if let end = row.assignment?.endAt {
                DetailRow(label: "Ends", value: end.appFormatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func policy(_ role: EligibleRole) -> some View {
        Section("Policy") {
            if role.policyFetchedAt == nil {
                Text("Policy unavailable").foregroundStyle(.secondary)
            } else {
                let required = String(localized: "Required"), notRequired = String(localized: "No")
                DetailRow(label: "Maximum",
                          value: role.maxDuration.flatMap(ISODuration.seconds).map { ISODuration.label($0) } ?? "—")
                DetailRow(label: "Justification", value: role.requiresJustification ? required : String(localized: "Optional"))
                DetailRow(label: "Ticket", value: role.requiresTicket ? required : notRequired)
                DetailRow(label: "MFA", value: role.requiresMFA ? required : notRequired)
                DetailRow(label: "Approval", value: role.requiresApproval ? required : notRequired)
            }
        }
    }

    /// This role's requests, under any account its account supersedes (latest first, at most 10).
    private func history(_ role: EligibleRole, supersession: Supersession) -> some View {
        let mine = records.filter { supersession.resolve(eligibleRoleId: $0.eligibleRoleId, source: $0.source) == role.id }
        return Section("History") {
            if mine.isEmpty {
                Text("No request yet").foregroundStyle(.secondary)
            }
            ForEach(mine.prefix(10)) { record in RecordRow(record: record) }
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

/// A label and its value on one line, or the value under the label when it does not fit (long scope path, large
/// Dynamic Type): never truncated.
struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
