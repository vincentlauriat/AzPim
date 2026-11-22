import AzPimCore
import ServiceManagement
import SwiftData
import SwiftUI

@main
struct AzPimApp: App {
    @State private var updater = UpdaterController()
    private let container: ModelContainer
    @State private var accounts: AccountService
    @State private var store: RoleStore

    init() {
        #if DEBUG
        // Snapshot mode, or the host of the unit tests: memory only, before anything opens or migrates the user's store.
        if let env = SnapshotRunner.makeEnvironment() ?? SnapshotRunner.makeTestHostEnvironment() {
            container = env.container
            _accounts = State(initialValue: env.accounts)
            _store = State(initialValue: env.store)
            SnapshotRunner.run(env)
            return
        }
        #endif
        let migrating = AzPimStore.needsLegacyMigration()
        // A store being written by AzurePim could be copied half-way: ask to quit it first.
        if migrating, !NSRunningApplication.runningApplications(withBundleIdentifier: PreferenceKeys.legacyDomain).isEmpty {
            Self.stop("Quit AzurePim, then open AzPim again.",
                      info: "AzPim copies AzurePim's favorites and history once, on its first launch, "
                        + "and cannot do it while AzurePim is running.", code: 0)
        }
        do {
            // 0.9.x shipped as AzurePim: copy its store once, so favorites and history survive the rename.
            try AzPimStore.migrateLegacyStore()
        } catch {
            Self.stop("AzPim could not copy AzurePim's data.",
                      info: "From \(AzPimStore.legacyURL.path) to \(AzPimStore.defaultURL.path): \(error)\n"
                        + "AzurePim's data was not changed.")
        }
        do {
            container = try AzPimStore.makeContainer()
        } catch {
            if migrating {
                // Do not keep a copy that cannot open: remove it (only the AzPim files); the next launch retries.
                AzPimStore.storeFiles(AzPimStore.defaultURL).forEach { try? FileManager.default.removeItem(at: $0) }
                Self.stop("AzPim could not open the data copied from AzurePim.",
                          info: "The copy at \(AzPimStore.defaultURL.path) was removed; AzurePim's data at "
                            + "\(AzPimStore.legacyURL.path) was not changed.\n\(error)")
            }
            // The local store is required; failing silently to memory would lose favorites and history.
            fatalError("AzPim could not open its local store at \(AzPimStore.defaultURL.path): \(error)")
        }
        Self.adoptLegacySetup(context: container.mainContext)
        let accountService = AccountService(context: container.mainContext)
        _accounts = State(initialValue: accountService)
        let notifications = NotificationScheduler()
        let roleStore = RoleStore(context: container.mainContext, accounts: accountService, notifications: notifications)
        notifications.onExtend = { roleId in await roleStore.extend(eligibleRoleId: roleId) }
        notifications.onOpen = { roleId in
            NSApp.activate(ignoringOtherApps: true)
            // Routed like a deep link: opens the main window on that role in the Roles Window.
            if let url = DeepLinkHandler.roleURL(roleId) { NSWorkspace.shared.open(url) }
        }
        _store = State(initialValue: roleStore)
        // Started at launch, independent of any view (a menu bar label is not guaranteed to run `.task`).
        DeepLinkHandler.store = roleStore
        // Global shortcut (default ⌃⌥P) → quick-activate palette. Production path only: snapshots and the test host
        // returned above and never take the shortcut from the user's session.
        let palette = QuickPaletteController(container: container, accounts: accountService, store: roleStore)
        GlobalHotKey.onPress = { palette.toggle() }
        Task { @MainActor in roleStore.start(); GlobalHotKey.registerStored() }
    }

    /// Shows a launch error and quits: used before any window exists, so it cannot be a sheet.
    private static func stop(_ message: String, info: String, code: Int32 = 1) -> Never {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = code == 0 ? .informational : .critical
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(code)
    }

    /// Once, after the AzurePim -> AzPim rename: carries over the app's own preferences (so "links may activate
    /// favorites" stays off for whoever turned it off) and, when the user had launch at login, registers AzPim
    /// itself, since onboarding will not run again. Runs while AzurePim's data exists and the marker is not set;
    /// safe to retry, `copyLegacy` never overwrites.
    private static func adoptLegacySetup(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PreferenceKeys.legacyAdopted),
              defaults.persistentDomain(forName: PreferenceKeys.legacyDomain) != nil
                || FileManager.default.fileExists(atPath: AzPimStore.legacyURL.path) else { return }
        if let domain = Bundle.main.bundleIdentifier {
            PreferenceKeys.copyLegacy(into: defaults, domain: domain)
        }
        if let settings = try? AzPimStore.settings(in: context), settings.onboardingCompleted, settings.launchAtLogin {
            // Unsigned debug builds cannot register; the status below then records it as off.
            try? SMAppService.mainApp.register()
            // What macOS actually registered, not what was asked (as in onboarding).
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            guard (try? context.save()) != nil else { return }
        }
        defaults.set(true, forKey: PreferenceKeys.legacyAdopted)
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: PreferenceKeys.legacyDomain) != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "AzurePim is still installed."
                alert.informativeText = "AzPim replaces it and has copied its data. Remove AzurePim from "
                    + "Applications and its entry from System Settings › General › Login Items."
                alert.runModal()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        Window("AzPim", id: WindowID.main) {
            MainWindow()
                .frame(minWidth: 760, minHeight: 480)
                .onOpenURL { DeepLinkHandler.handle($0) }
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
        .defaultSize(width: 980, height: 640)
        .handlesExternalEvents(matching: ["open", "activate", "role"])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Welcome to AzPim", id: WindowID.onboarding) {
            OnboardingView()
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["onboarding"])

        WindowGroup("Admin consent", id: WindowID.consent, for: UUID.self) { $accountId in
            AdminConsentSheet(accountId: accountId)
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView(updater: updater)
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
    static let consent = "consent"
}
