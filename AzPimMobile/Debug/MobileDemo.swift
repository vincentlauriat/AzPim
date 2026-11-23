#if DEBUG
import AzPimCore
import SwiftData
import SwiftUI

/// Debug only: `AZPIM_DEMO=<screen>` runs the app on the Mac snapshots' fixtures (`DemoFixtures`, Microsoft account
/// only) in an in-memory store, so the UI can be checked without a tenant. Nothing reaches Microsoft or the Keychain:
/// the store is never refreshed and every token request fails. From the command line:
/// `SIMCTL_CHILD_AZPIM_DEMO=roles xcrun simctl launch booted fr.vincentlauriat.azpim.ios`.
/// Screens: `roles` (default), `eligible` (scrolled to the eligible roles), `onboarding`, `activate` (Activation
/// Sheet open), `settings`.
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

    /// Opens the screen asked for once the roles list is shown.
    static func initialRole(in store: RoleStore) -> EligibleRole? {
        guard screen == "activate" else { return nil }
        let roles = (try? store.context.fetch(FetchDescriptor<EligibleRole>())) ?? []
        return roles.first { $0.roleName == "Global Reader" }
    }

    static var showsSettings: Bool { screen == "settings" }
}
#endif
