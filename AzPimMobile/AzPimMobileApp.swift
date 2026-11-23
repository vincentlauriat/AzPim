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

    init() {
        #if DEBUG
        // Demo mode (`AZPIM_DEMO`): fixture data in memory, nothing sent to Microsoft.
        if let demo = MobileDemo.makeEnvironment() {
            container = demo.container
            _accounts = State(initialValue: demo.accounts)
            _store = State(initialValue: demo.store)
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
        Task { @MainActor in roleStore.start() }
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                // Microsoft Authenticator (broker) and the system web session return through the msauth redirect URI.
                .onOpenURL { url in
                    _ = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                }
                .environment(accounts)
                .environment(store)
                .modelContainer(container)
        }
    }
}
