import AzPimCore
import MSAL
import SwiftData
import SwiftUI

/// AzPim for iPhone (2.0): the Mac app's store and services (`AzPim/Services`) under a compact SwiftUI UI.
/// Microsoft sign-in only (MSAL with the Microsoft Authenticator broker); no Azure CLI, no Sparkle.
@main
struct AzPimMobileApp: App {
    private let container: ModelContainer
    @State private var accounts: AccountService
    @State private var store: RoleStore
    @State private var liveActivity: LiveActivityController
    /// The home-screen and lock-screen widgets' snapshot (2.0 step 4b).
    private let widgetSnapshots: WidgetSnapshotWriter

    init() {
        #if DEBUG
        // Demo mode (`AZPIM_DEMO`): fixture data in memory, nothing sent to Microsoft.
        if let demo = MobileDemo.makeEnvironment() {
            container = demo.container
            _accounts = State(initialValue: demo.accounts)
            _store = State(initialValue: demo.store)
            let controller = Self.liveActivity(for: demo.store)
            controller.demoAllowed = MobileDemo.screen == "liveactivity"
            _liveActivity = State(initialValue: controller)
            widgetSnapshots = WidgetSnapshotWriter(store: demo.store)
            widgetSnapshots.demoAllowed = MobileDemo.screen == "widgets"
            return
        }
        #endif
        do {
            container = try AzPimStore.makeContainer()
        } catch {
            // The local store is required; failing silently to memory would lose favorites and history.
            fatalError("AzPim could not open its local store at \(AzPimStore.defaultURL.path): \(error)")
        }
        let accountService = AccountService(context: container.mainContext)
        _accounts = State(initialValue: accountService)
        let notifications = NotificationScheduler()
        let roleStore = RoleStore(context: container.mainContext, accounts: accountService, notifications: notifications)
        notifications.onExtend = { roleId in await roleStore.extendFromNotification(eligibleRoleId: roleId) }
        notifications.onOpen = { roleId in roleStore.focusedRoleId = roleId }
        _store = State(initialValue: roleStore)
        _liveActivity = State(initialValue: Self.liveActivity(for: roleStore))
        widgetSnapshots = WidgetSnapshotWriter(store: roleStore)
        Task { @MainActor in roleStore.start() }
    }

    /// The Live Activity follows every refresh; its Extend button runs the store's Extend in this process.
    private static func liveActivity(for store: RoleStore) -> LiveActivityController {
        let controller = LiveActivityController(store: store)
        ExtendRoleActivityIntent.register(store: store)
        return controller
    }

    var body: some Scene {
        WindowGroup {
            root
                // Microsoft Authenticator (broker) and the system web session return through the msauth redirect URI.
                .onOpenURL { url in
                    _ = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                }
                .environment(accounts)
                .environment(store)
                .environment(liveActivity)
                .modelContainer(container)
        }
    }

    private var root: some View {
        #if DEBUG
        MobileRootView(navigation: MobileDemo.navigation(in: store))
            .task { await MobileDemo.applyOrientation() }
            .task { await MobileDemo.startLiveActivity(liveActivity) }
            .overlay { if MobileDemo.screen == "widgets" { WidgetGallery() } }
        #else
        MobileRootView()
        #endif
    }
}
