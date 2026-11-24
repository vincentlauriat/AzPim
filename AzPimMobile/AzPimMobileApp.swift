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
    /// Owned here, not by the root view: the Control Center control's intent can run on a cold launch, before any view.
    @State private var navigation: MobileNavigation

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
            let demoNavigation = MobileDemo.navigation(in: demo.store)
            Self.registerControl(navigation: demoNavigation)
            _navigation = State(initialValue: demoNavigation)
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
        // Extend opens the app on iPhone (`NotificationScheduler.extendOpensApp`): the role is shown while it runs, and
        // a cold launch first waits for the launch refresh, as the Live Activity's Extend does.
        notifications.onExtend = { roleId in
            roleStore.focusedRoleId = roleId
            do {
                try await roleStore.intentReady()
            } catch {
                return (error as? RoleStore.IntentFailure)?.message ?? error.localizedDescription
            }
            return await roleStore.extendFromNotification(eligibleRoleId: roleId)
        }
        notifications.onOpen = { roleId in roleStore.focusedRoleId = roleId }
        _store = State(initialValue: roleStore)
        _liveActivity = State(initialValue: Self.liveActivity(for: roleStore))
        let mobileNavigation = MobileNavigation()
        Self.registerControl(navigation: mobileNavigation)
        _navigation = State(initialValue: mobileNavigation)
        Task { @MainActor in roleStore.start() }
    }

    /// The Live Activity follows every refresh; its Extend button runs the store's Extend in this process.
    private static func liveActivity(for store: RoleStore) -> LiveActivityController {
        let controller = LiveActivityController(store: store)
        ExtendRoleActivityIntent.register(store: store)
        return controller
    }

    /// The Control Center control « Run Favorite » opens the favorite chooser; a favorite runs only from its sheet.
    private static func registerControl(navigation: MobileNavigation) {
        OpenFavoritesIntent.handler = { [weak navigation] in navigation?.choosingFavorite = true }
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
        MobileRootView(navigation: navigation)
            .task { await MobileDemo.applyOrientation() }
            .task { await MobileDemo.startLiveActivity(liveActivity) }
        #else
        MobileRootView(navigation: navigation)
        #endif
    }
}
