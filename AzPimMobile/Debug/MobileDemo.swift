#if DEBUG
import AzPimCore
import SwiftData
import SwiftUI
import UIKit

/// Debug only: `AZPIM_DEMO=<screen>` runs the app on the Mac snapshots' fixtures (`DemoFixtures`, Microsoft account
/// only) in an in-memory store, so the UI can be checked without a tenant. Nothing reaches Microsoft or the Keychain:
/// the store is never refreshed and every token request fails. From the command line:
/// `SIMCTL_CHILD_AZPIM_DEMO=roles xcrun simctl launch <device> fr.vincentlauriat.azpim.ios`.
/// Screens: `roles` (default), `eligible` (scrolled to the eligible roles), `onboarding`, `activate` (Activation
/// Sheet open), `settings`, `history`, `detail` (Contributor selected: its detail, pushed in compact width, in the
/// detail column in regular width), `fold` (Contributor selected and the Activation Sheet open, then the app turns to
/// landscape after 4 s: on a Max that is a real compact → regular size-class change, as unfolding the iPhone Duo).
/// `empty` (no active role: the panel's empty dial).
/// `liveactivity` (the roles screen, and the Live Activity of the activation that ends first: go home or lock to see it).
/// `AZPIM_ORIENTATION=landscape` turns the app to landscape at launch (the regular layout on a Max).
@MainActor
enum MobileDemo {
    static var screen: String? {
        ProcessInfo.processInfo.environment["AZPIM_DEMO"].map { $0.isEmpty || $0 == "1" ? "roles" : $0 }
    }

    struct Environment {
        let container: ModelContainer
        let accounts: AccountService
        let store: RoleStore
    }

    static func makeEnvironment() -> Environment? {
        guard let screen, let demo = try? AzPimStore.makeContainer(inMemory: true) else { return nil }
        let context = demo.mainContext
        if screen != "onboarding" {
            (try? AzPimStore.settings(in: context))?.onboardingCompleted = true
            DemoFixtures.add(context: context, azureCLI: false)
            // Policies known, as after a refresh: the Activation Sheet never asks Azure.
            for role in (try? context.fetch(FetchDescriptor<EligibleRole>())) ?? [] {
                role.policy = RolePolicy(maxDuration: "PT8H", requiresTicket: role.roleName == "Security Reader")
            }
            // `empty`: no role active, the panel's empty dial.
            if screen == "empty" { try? context.delete(model: ActiveAssignment.self) }
        }
        try? context.save()
        let accounts = AccountService(context: context)
        let store = RoleStore(context: context, accounts: accounts, notifications: NotificationScheduler())
        store.snapshotFrozen = true
        store.durationMemory = .inMemory()
        store.ticketMemory = .inMemory()
        store.tokenProvider = { _ in throw TokenError.failed("Demo mode: nothing is sent to Microsoft.") }
        store.snapshotRefreshed(at: .now)
        Task { @MainActor in store.start() }   // the countdown clock (the refresh loop does nothing when frozen)
        return Environment(container: demo, accounts: accounts, store: store)
    }

    /// The selection and sheets of the screen asked for.
    static func navigation(in store: RoleStore) -> MobileNavigation {
        guard screen != nil else { return MobileNavigation() }   // no demo: no fetch on every App body evaluation
        let roles = (try? store.context.fetch(FetchDescriptor<EligibleRole>())) ?? []
        let named = { (name: String) in roles.first { $0.roleName == name && $0.account?.mode == .msal } }
        return switch screen {
        case "activate": MobileNavigation(activating: named("Global Reader"))
        case "settings": MobileNavigation(showSettings: true)
        case "history": MobileNavigation(showHistory: true)
        case "detail": MobileNavigation(selection: named("Contributor")?.id)
        case "fold": MobileNavigation(selection: named("Contributor")?.id, activating: named("Global Reader"))
        default: MobileNavigation()
        }
    }

    /// `liveactivity`: the Live Activity of the fixtures' activation that ends first, started once the app is in the
    /// foreground (the only time ActivityKit allows it). Go home or lock the screen to see it. Other screens: none.
    static func startLiveActivity(_ controller: LiveActivityController) async {
        guard screen == "liveactivity" else { return }
        for _ in 0..<20 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(250))
        }
        controller.sync()
    }

    /// Turns the app to landscape (`AZPIM_ORIENTATION=landscape` at launch, `fold` after 4 s); simctl cannot rotate.
    static func applyOrientation() async {
        let asked = ProcessInfo.processInfo.environment["AZPIM_ORIENTATION"] == "landscape"
        guard asked || screen == "fold" else { return }
        if screen == "fold" { try? await Task.sleep(for: .seconds(4)) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }
}
#endif
