import AzPimCore
import SwiftData
import SwiftUI

/// Onboarding until an account is signed in, then the roles list. Coming back to the foreground refreshes data
/// older than a minute, as opening the Mac panel does.
struct MobileRootView: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Query private var accountList: [Account]

    var body: some View {
        Group {
            if accountList.isEmpty {
                MobileOnboardingView()
            } else {
                #if DEBUG
                RolesScreen(showSettings: MobileDemo.showsSettings, activating: MobileDemo.initialRole(in: store))
                #else
                RolesScreen()
                #endif
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.panelOpenedAt = .now
            Task { await store.refreshIfStale() }
        }
    }
}
