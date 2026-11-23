import AzPimCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Onboarding (AppFlow › First use): privacy promise, sign-in mode (Microsoft recommended, Azure CLI for Azure roles
/// only), then a summary of the account added with notifications, launch at login and the palette shortcut.
struct OnboardingView: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var notifications = true
    @State private var launchAtLogin = true
    /// Login item problem shown on the last page; the next Done closes the window.
    @State private var loginItemError: String?
    /// Counts of the account just added, read after its first refresh; nil when the sign-in was skipped.
    @State private var added: (eligible: Int, active: Int)?

    init(page: Int = 0, added: (eligible: Int, active: Int)? = nil) {
        _page = State(initialValue: page)
        _added = State(initialValue: added)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: signIn
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520, height: 420)
        .task {
            #if DEBUG
            if store.snapshotFrozen { return }   // snapshots and the test host never run `az`
            #endif
            await accounts.refreshCLIStatus()
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Welcome to AzPim").font(.title2.weight(.semibold))
            Text("Activate, track and end your Microsoft PIM roles from the menu bar.")
                .multilineTextAlignment(.center)
            Label("No server, no telemetry: your tokens never leave this Mac except to Microsoft.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should AzPim sign in?").font(.title3.weight(.semibold))
            // The client ID is built in (Info.plist `AzPimClientID`): hidden only in a build without one.
            if accounts.isMSALConfigured {
                Button {
                    run { try await accounts.addMSALAccount() }
                } label: {
                    Label("Sign in with Microsoft", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
                .disabled(busy)
                Text("Recommended: Azure roles, Entra roles and PIM groups (Entra roles need your admin's consent).")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            cliOption
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
        }
    }

    @ViewBuilder private var cliOption: some View {
        switch accounts.cliStatus {
        case .signedIn(let identity):
            Button {
                run { try await accounts.addCLIAccount() }
            } label: {
                Label("Use Azure CLI (\(identity.upn), \(identity.tenantName ?? identity.tenantId))",
                      systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(busy)
            Text("Azure roles only, no admin consent needed.").font(.caption).foregroundStyle(.secondary)
        case .notSignedIn(let command):
            Label("Azure CLI found but not signed in — run `\(command)` then retry.", systemImage: "terminal")
            Button("Retry") { Task { await accounts.refreshCLIStatus() } }
        case .notInstalled:
            Label("Azure CLI not found (optional).", systemImage: "terminal").foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        case .unknown:
            ProgressView("Looking for the Azure CLI…").controlSize(.small)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let added {
                Label(RoleStore.summaryText(eligible: added.eligible, active: added.active), systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
            } else {
                Label("No account yet: add one later in Settings › Accounts.", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.headline)
            }
            Form {
                Toggle("Notify me before an activation expires", isOn: $notifications)
                Toggle("Launch AzPim at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { loginItemError = nil }   // Done tries again with the new choice
                if let loginItemError { Text(loginItemError).foregroundStyle(Theme.danger) }
                Label("Press \(shortcut) in any app to search your roles and activate one.", systemImage: "keyboard")
            }
            .formStyle(.grouped)
        }
    }

    /// The palette shortcut registered at launch (⌃⌥P unless changed in Settings › General).
    private var shortcut: String {
        (GlobalHotKey.current ?? GlobalShortcut.defaultShortcut).display
    }

    private var footer: some View {
        HStack {
            if page > 0 { Button("Back") { page -= 1 } }
            Spacer()
            if page == 1 { Button("Skip") { page = 2 } }
            Button(page == 2 ? "Done" : "Continue") {
                if page < 2 { page += 1 } else { Task { await complete() } }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Account) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let account = try await action()
                // Counted after the first refresh, then shown: the summary never reads zeros from an empty cache.
                await store.refresh()
                added = store.summary(of: account)
                page = 2
            } catch {
                self.error = AccountService.message(for: error)
            }
        }
    }

    private func complete() async {
        // The problem is on screen: this Done closes the window.
        guard loginItemError == nil else {
            dismissWindow(id: WindowID.onboarding)
            return
        }
        if notifications {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try? await SMAppService.mainApp.unregister() }
        } catch {
            // Unsigned debug builds cannot register.
            loginItemError = String(localized: """
                Launch at login: \(error.localizedDescription) \
                You can change it later in System Settings › General › Login Items.
                """)
        }
        let status = SMAppService.mainApp.status
        if launchAtLogin, loginItemError == nil, status == .requiresApproval {
            loginItemError = String(localized: "Launch at login needs your approval in System Settings › General › Login Items.")
        }
        let settings = accounts.settings
        // What macOS actually registered, not what was asked.
        settings.launchAtLogin = status == .enabled
        settings.onboardingCompleted = true
        if loginItemError == nil { dismissWindow(id: WindowID.onboarding) }
    }
}
