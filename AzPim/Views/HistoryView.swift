import AzPimCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// History Window (AppFlow, T4.3 + T4.5): local records, requests pending approval, median time-to-activation, CSV export.
struct HistoryView: View {
    @Environment(RoleStore.self) private var store
    @Environment(AccountService.self) private var accountService
    @Query(sort: \ActivationRecord.sentAt, order: .reverse) private var records: [ActivationRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var exporting = false
    @State private var csv = CSVDocument(text: "")
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
        VStack(alignment: .leading, spacing: 0) {
            summary.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if records.isEmpty && externalPending.isEmpty {
                ContentUnavailableView("No request yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Activations and deactivations sent by AzPim appear here."))
            } else {
                List {
                    ForEach(accounts.filter { store.pendingErrors[$0.id] != nil }) { account in
                        Label("Couldn't fetch pending requests: \(store.pendingErrors[account.id] ?? "")",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning).font(.callout)
                    }
                    if !externalPending.isEmpty {
                        Section("Pending approval (sent elsewhere)") {
                            ForEach(externalPending, id: \.1.id) { account, request in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(request.displayRoleName) — \(request.displayScopeName)")
                                        Text(request.createdAt?.appFormatted(date: .abbreviated, time: .shortened) ?? "")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    cancelButton(id: request.id, source: request.source, account: account)
                                }
                            }
                        }
                    }
                    Section("Requests") {
                        ForEach(records) { record in
                            HistoryRow(record: record) {
                                if record.status == .pendingApproval, let id = record.remoteRequestId, let account = record.account {
                                    cancelButton(id: id, source: record.source, account: account)
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            Button {
                csv = CSVDocument(text: HistoryCSV.make(records))
                exporting = true
            } label: {
                Label("Export CSV…", systemImage: "square.and.arrow.up")
            }
            .disabled(records.isEmpty)
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .fileExporter(isPresented: $exporting, document: csv,
                      contentType: .commaSeparatedText, defaultFilename: String(localized: "AzPim history")) { _ in }
        .navigationTitle("History")
        .onAppear {
            store.historyVisible = true
            Task { await store.refresh() }
        }
        .onDisappear { store.historyVisible = false }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            StatTile(label: String(localized: "Median time to activate"),
                     value: ActivationStats.medianTimeToActivation(records).map(Self.seconds) ?? "—",
                     note: String(localized: "Panel opened → role provisioned"), tint: Theme.accent, icon: "stopwatch")
            StatTile(label: String(localized: "Activations"),
                     value: "\(records.filter { $0.action != .deactivate && $0.status == .provisioned }.count)",
                     note: String(localized: "Provisioned, kept \(retentionDays) days"), tint: Theme.active, icon: "bolt.fill")
            StatTile(label: String(localized: "Pending approval"),
                     value: "\(records.filter { $0.status == .pendingApproval }.count + externalPending.count)",
                     note: String(localized: "Including requests sent elsewhere"), tint: Theme.warning, icon: "clock")
        }
    }

    private var retentionDays: Int { accountService.settings.historyRetentionDays }

    /// « 12.3 sec » / « 12,3 s ».
    static func seconds(_ value: TimeInterval) -> String {
        Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))
                .locale(AppLanguage.locale))
    }

    @ViewBuilder private func cancelButton(id: String, source: RoleSource, account: Account) -> some View {
        if canceling.contains(id) {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Cancel request") {
                    canceling.insert(id)
                    Task {
                        cancelErrors[id] = await store.cancel(requestId: id, source: source, account: account)
                        canceling.remove(id)
                    }
                }
                .controlSize(.small)
                if let error = cancelErrors[id] {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
        }
    }
}

private struct HistoryRow<Trailing: View>: View {
    let record: ActivationRecord
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let error = record.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(color)
            trailing
        }
        .padding(.vertical, 2)
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
        if let time = record.timeToActivation { parts.append(String(localized: "\(HistoryView.seconds(time)) to activate")) }
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

struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
