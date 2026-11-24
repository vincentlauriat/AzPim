import AzPimCore
import SwiftData
import SwiftUI

/// History on iPhone (both layouts, from the toolbar), as the Mac History window: median time to activate, requests
/// waiting for an approver (sent by AzPim or elsewhere, each with Cancel request), then every request AzPim sent.
struct MobileHistoryView: View {
    @Environment(RoleStore.self) private var store
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ActivationRecord.sentAt, order: .reverse) private var records: [ActivationRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var cancelErrors: [String: String] = [:]
    @State private var canceling: Set<String> = []

    /// Pending requests not sent by AzPim (portal, other tools): shown on top of local records.
    private var externalPending: [(Account, RemoteRequest)] {
        let local = Set(records.compactMap { $0.remoteRequestId?.lowercased() })
        return accounts.flatMap { account in
            (store.pending[account.id] ?? []).filter { !local.contains($0.id.lowercased()) }.map { (account, $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                summary
                ForEach(accounts.filter { store.pendingErrors[$0.id] != nil }) { account in
                    Label("Couldn't fetch pending requests: \(store.pendingErrors[account.id] ?? "")",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning).font(.callout)
                }
                if !externalPending.isEmpty {
                    Section("Pending approval (sent elsewhere)") {
                        ForEach(externalPending, id: \.1.id) { account, request in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(request.displayRoleName) — \(request.displayScopeName)")
                                Text(request.createdAt?.appFormatted(date: .abbreviated, time: .shortened) ?? "")
                                    .font(.footnote).foregroundStyle(.secondary)
                                cancelButton(id: request.id, source: request.source, account: account)
                            }
                        }
                    }
                }
                Section("Requests") {
                    if records.isEmpty {
                        ContentUnavailableView("No request yet", systemImage: "clock.arrow.circlepath",
                                               description: Text("Activations and deactivations sent by AzPim appear here."))
                    }
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            RecordRow(record: record)
                            if record.status == .pendingApproval, let id = record.remoteRequestId, let account = record.account {
                                cancelButton(id: id, source: record.source, account: account)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if store.isRefreshing { ProgressView() }
                }
            }
        }
        .onAppear {
            // Pending requests are listed on every refresh while History is shown.
            store.historyVisible = true
            Task { await store.refresh() }
        }
        .onDisappear { store.historyVisible = false }
    }

    private var summary: some View {
        Section {
            DetailRow(label: "Median time to activate",
                      value: ActivationStats.medianTimeToActivation(records).map(Self.seconds) ?? "—")
            DetailRow(label: "Activations",
                      value: "\(records.filter { $0.action != .deactivate && $0.status == .provisioned }.count)")
            DetailRow(label: "Pending approval",
                      value: "\(records.filter { $0.status == .pendingApproval }.count + externalPending.count)")
        } footer: {
            Text("Provisioned, kept \(accountService.settings.historyRetentionDays) days")
        }
    }

    /// « 12.3 sec » / « 12,3 s ».
    static func seconds(_ value: TimeInterval) -> String {
        Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))
                .locale(AppLanguage.locale))
    }

    @ViewBuilder private func cancelButton(id: String, source: RoleSource, account: Account) -> some View {
        if canceling.contains(id) {
            ProgressView()
        } else {
            Button("Cancel request", role: .destructive) {
                canceling.insert(id)
                Task {
                    cancelErrors[id] = await store.cancel(requestId: id, source: source, account: account)
                    canceling.remove(id)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            if let error = cancelErrors[id] {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }
}

/// One request: what was asked, when, for how long, its status (History, role detail).
struct RecordRow: View {
    let record: ActivationRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(statusText).font(.footnote.weight(.semibold)).foregroundStyle(color)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                if let error = record.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// « Activate Reader — Tenant Root Group ».
    private var title: String {
        let role = record.displayRoleName, scope = record.displayScopeName
        return switch record.action {
        case .activate: String(localized: "Activate \(role) — \(scope)")
        case .deactivate: String(localized: "Deactivate \(role) — \(scope)")
        case .extend: String(localized: "Extend \(role) — \(scope)")
        }
    }

    private var detail: String {
        var parts = [record.sentAt.appFormatted(date: .abbreviated, time: .shortened)]
        if let duration = record.requestedDuration, let seconds = ISODuration.seconds(duration) {
            parts.append(ISODuration.label(seconds))
        }
        if let time = record.timeToActivation {
            parts.append(String(localized: "\(MobileHistoryView.seconds(time)) to activate"))
        }
        if let favorite = record.viaFavorite { parts.append("★ \(favorite)") }
        if let justification = record.justification, !justification.isEmpty { parts.append("“\(justification)”") }
        if let account = record.account?.upn { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch record.status {
        case .pendingApproval: String(localized: "Pending approval")
        case .sent: String(localized: "Sent")
        case .provisioned: String(localized: "Provisioned")
        case .denied: String(localized: "Denied")
        case .canceled: String(localized: "Canceled")
        case .failed: String(localized: "Failed")
        }
    }

    private var icon: String {
        switch record.status {
        case .provisioned: "checkmark.circle.fill"
        case .pendingApproval, .sent: "clock"
        case .denied, .failed: "xmark.octagon.fill"
        case .canceled: "minus.circle"
        }
    }

    private var color: Color {
        switch record.status {
        case .provisioned: Theme.active
        case .pendingApproval, .sent: Theme.warning
        case .denied, .failed: Theme.danger
        case .canceled: .secondary
        }
    }
}
