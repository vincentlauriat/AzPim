import AzPimCore
import SwiftData
import SwiftUI

/// Settings on iPhone: the signed-in accounts (Entra roles access, admin consent, sign-out) and adding another one.
struct MobileSettingsView: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @State private var busy = false
    @State private var error: String?
    @State private var signingOut: Account?
    @State private var consentAccount: Account?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(accountList) { account in accountRow(account) }
                    Button {
                        Task { await addAccount() }
                    } label: {
                        Label("Add a Microsoft account", systemImage: "plus.circle")
                    }
                    .disabled(busy || !accounts.isMSALConfigured)
                } header: {
                    Text("Accounts")
                } footer: {
                    if let error { Text(error).foregroundStyle(Theme.danger) }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text("No server, no telemetry: your tokens never leave this iPhone except to Microsoft.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $consentAccount) { account in
                NavigationStack {
                    ScrollView { AdminConsentSheet(accountId: account.id) }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { consentAccount = nil } } }
                }
            }
            .confirmationDialog(signingOut.map { "Sign out \($0.upn)?" } ?? "",
                                isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
                                titleVisibility: .visible, presenting: signingOut) { account in
                Button("Sign out", role: .destructive) { signOut(account) }
            } message: { _ in
                Text("AzPim forgets this account on this iPhone. Your roles in Azure do not change.")
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(account.upn).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(account.tenantName ?? account.tenantId).font(.footnote).foregroundStyle(.secondary)
            HStack {
                switch account.directoryAccess {
                case .enabled:
                    Label("Entra roles enabled", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(Theme.active)
                case .consentRequired:
                    Button("Admin consent required…") { consentAccount = account }
                        .font(.footnote).buttonStyle(.borderless)
                case .notRequested:
                    Button("Enable Entra roles") { Task { await enableDirectory(account) } }
                        .font(.footnote).buttonStyle(.borderless).disabled(busy)
                case .notApplicable:
                    EmptyView()
                }
                Spacer()
                Button("Sign out", role: .destructive) { signingOut = account }
                    .font(.footnote).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func addAccount() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await accounts.addMSALAccount()
            await store.refresh()
        } catch {
            self.error = AccountService.message(for: error)
        }
    }

    private func enableDirectory(_ account: Account) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await accounts.enableDirectoryAccess(for: account)
            await store.refresh()
        } catch {
            self.error = AccountService.message(for: error)
        }
    }

    private func signOut(_ account: Account) {
        do {
            try accounts.remove(account)
        } catch {
            self.error = AccountService.message(for: error)
        }
    }
}
