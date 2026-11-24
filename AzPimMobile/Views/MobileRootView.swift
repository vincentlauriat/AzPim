import AzPimCore
import SwiftData
import SwiftUI

/// Onboarding until an account is signed in, then the roles: the panel in compact width (iPhone, iPhone Duo folded),
/// a split view (roles list | role detail) in regular width (iPhone Duo unfolded, any iPhone in landscape). The selection,
/// the sheets and the deactivate question are held here, above that switch, so a fold or an unfold keeps them.
/// Coming back to the foreground refreshes data older than a minute, as opening the Mac panel does.
struct MobileRootView: View {
    @Environment(RoleStore.self) private var store
    @Environment(LiveActivityController.self) private var liveActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var accountList: [Account]
    @State private var navigation: MobileNavigation

    init(navigation: MobileNavigation = MobileNavigation()) {
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        @Bindable var navigation = navigation
        GeometryReader { geometry in
            Group {
                if accountList.isEmpty {
                    MobileOnboardingView()
                } else if MobileLayout.isRegular(sizeClass: sizeClass, width: MobileLayout.windowWidth(geometry)) {
                    // The split view collapses to one column in a compact size class: wide enough is regular.
                    RolesSplitView().environment(\.horizontalSizeClass, .regular)
                } else {
                    RolesScreen()
                }
            }
        }
        .environment(navigation)
        .sheet(item: $navigation.activating) { role in
            ScrollView { ActivationSheet(role: role) { navigation.activating = nil }.padding(.top, 8) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $navigation.askingFavorite) { request in
            ScrollView { FavoriteActivationSheet(request: request) { navigation.askingFavorite = nil }.padding(.top, 8) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $navigation.showSettings) { MobileSettingsView() }
        .sheet(isPresented: $navigation.showHistory) { MobileHistoryView() }
        .confirmationDialog(navigation.deactivating.map { String(localized: "Deactivate \($0.displayRoleName)?") } ?? "",
                            isPresented: Binding(get: { navigation.deactivating != nil },
                                                 set: { if !$0 { navigation.deactivating = nil } }),
                            titleVisibility: .visible, presenting: navigation.deactivating) { assignment in
            Button("Deactivate", role: .destructive) { Task { await store.deactivate(assignment) } }
        } message: { assignment in
            Text(assignment.displayScopeName)
        }
        // Favorites widget: the favorite's confirmation (MSAL's redirect stays with the App's handler).
        .onOpenURL { navigation.openFavorite($0, store: store) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.panelOpenedAt = .now
            // A Live Activity can only start in the foreground: a role activated elsewhere gets one now.
            liveActivity.sync()
            Task { await store.refreshIfStale() }
        }
    }
}
