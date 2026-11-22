import AzPimCore
import MSAL
import ServiceManagement
import SwiftData
import SwiftUI

/// Settings scene: General, Accounts Settings, About.
struct SettingsView: View {
    let updater: UpdaterController
    @Environment(AccountService.self) private var accounts

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            Form {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Core", value: AzPimCore.version)
                LabeledContent("MSAL", value: MSALPublicClientApplication.sdkVersion ?? "?")
                LabeledContent("Sparkle", value: updater.sparkleVersion)
                LabeledContent("Microsoft sign-in", value: accounts.isMSALConfigured ? "Configured" : "No client ID")
                if updater.isEnabled {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

/// Settings › General: launch at login, as macOS reports it (System Settings › Login Items can change it at any time).
struct GeneralSettingsView: View {
    @Environment(AccountService.self) private var accounts
    @Environment(\.modelContext) private var context
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                // On while registered, including while it waits for approval.
                Toggle("Launch AzPim at login", isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { setLaunchAtLogin($0) }))
                if status == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Needs your approval in System Settings › General › Login Items.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readStatus()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Unsigned debug builds cannot register.
            self.error = "Launch at login: \(error.localizedDescription)"
        }
        readStatus()
    }

    /// Shows what macOS registered and keeps the stored setting in step (as onboarding records it: on only when enabled).
    private func readStatus() {
        status = SMAppService.mainApp.status
        let settings = accounts.settings
        let enabled = status == .enabled
        guard settings.launchAtLogin != enabled else { return }
        settings.launchAtLogin = enabled
        try? context.save()
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
