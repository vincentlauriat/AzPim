import AzPimCore
import SwiftData
import SwiftUI

@main
struct AzPimApp: App {
    @State private var updater = UpdaterController()
    private let container: ModelContainer
    @State private var accounts: AccountService
    @State private var store: RoleStore

    init() {
        do {
            // 0.9.x shipped as AzurePim: copy its store once, so favorites and history survive the rename.
            try AzPimStore.migrateLegacyStore()
            container = try AzPimStore.makeContainer()
        } catch {
            // The local store is required; failing silently to memory would lose favorites and history.
            fatalError("AzPim could not open its local store at \(AzPimStore.defaultURL.path): \(error)")
        }
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
        Task { @MainActor in roleStore.start() }
        #if DEBUG
        SnapshotRunner.run(container: container, accounts: accountService, store: roleStore)
        #endif
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
