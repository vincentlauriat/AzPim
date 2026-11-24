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
            ContentUnavailableView("Select a role", systemImage: "key.horizontal")
        }
    }

    // MARK: Sections

    private func header(_ row: RoleRow) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: SourceIcon.name(row.source))
                        .foregroundStyle(row.assignment != nil ? Theme.active : Theme.accent)
                        .accessibilityHidden(true)
                    Text(row.displayRoleName).font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text(row.displayScopeName).foregroundStyle(.secondary)
                RoleStateText(row: row, now: store.now)
            }
            .padding(.vertical, 4)
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
                    let tooRecent = store.now.timeIntervalSince(assignment.startAt) < 300
                    Button(role: .destructive) { navigation.deactivating = assignment } label: {
                        Label("Deactivate…", systemImage: "stop.circle")
                    }
                    .disabled(tooRecent || store.isOffline)
                    if tooRecent {
                        Text("Can't deactivate within 5 minutes of activation.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    let block = activateBlock(role)
                    Button { navigation.activating = role } label: {
                        Label("Activate…", systemImage: "bolt.fill")
                    }
                    .disabled(block != nil)
                    if let block { Text(block.message).font(.footnote).foregroundStyle(.secondary) }
                }
                if let result = navigation.extendResult, result.roleId == role.id {
                    Text(result.text).font(.footnote)
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

    /// Read once per body; `store.now` follows the store clock (a sent request's 15-minute window).
    private func activateBlock(_ role: EligibleRole) -> ActivationBlock? {
        // Duration and form are the sheet's: only the state is checked here.
        ActivationBlock.reason(.init(inProgress: store.busy.contains(role.id),
                                     pending: store.waitingRequest(for: role, at: store.now) != nil,
                                     offline: store.isOffline, minutes: ActivationDuration.minMinutes(policyMax: role.maxDuration),
                                     policyMax: role.maxDuration, requiresJustification: false))
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
