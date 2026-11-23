#if DEBUG
import AppKit
import AzPimCore
import SwiftData
import SwiftUI

/// Debug only: `AZPIM_SNAPSHOT=<dir>` renders the panel and the main window sections to PNG files from fixture data,
/// so the look can be checked without clicking the status item. The app then runs on an in-memory store only: no
/// migration, no refresh, no `az`, no Keychain, and preferences are read from a throwaway defaults suite, so the
/// user's own data and settings are never touched.
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["AZPIM_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Defaults suite of the renders (`@AppStorage` reads it through `.defaultAppStorage`), removed at the end.
    static let suiteName = "fr.vincentlauriat.azpim.snapshot"

    struct Env {
        let container: ModelContainer
        let accounts: AccountService
        let store: RoleStore
    }

    /// The fixture environment the app runs on in snapshot mode; nil outside it.
    static func makeEnvironment() -> Env? {
        guard directory != nil, let demo = try? AzPimStore.makeContainer(inMemory: true) else { return nil }
        let context = demo.mainContext
        let settings = try? AzPimStore.settings(in: context)
        settings?.onboardingCompleted = true   // no onboarding window
        DemoFixtures.add(context: context)
        try? context.save()
        let accounts = AccountService(context: context)
        let store = RoleStore(context: context, accounts: accounts, notifications: NotificationScheduler())
        store.snapshotFrozen = true   // a window becoming key must not refresh the fixtures
        store.durationMemory = .inMemory()   // never the user's preferences
        store.ticketMemory = .inMemory()
        store.snapshotRefreshed(at: frozenRefresh)   // "Updated 09:41" in every render
        return Env(container: demo, accounts: accounts, store: store)
    }

    /// True when the app runs as the host of the unit tests (checked by the tests themselves).
    private(set) static var isTestHost = false

    /// Host of the unit tests: an empty in-memory store and nothing started (no refresh, no `az`, no Keychain, no
    /// migration, no login item). The tests build their own stores. Nil outside a test run.
    static func makeTestHostEnvironment() -> Env? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return nil }
        // Never fall through to the user's store under XCTest.
        let memory: ModelContainer
        do {
            memory = try AzPimStore.makeContainer(inMemory: true)
        } catch {
            fatalError("test host: in-memory store failed: \(error)")
        }
        isTestHost = true
        (try? AzPimStore.settings(in: memory.mainContext))?.onboardingCompleted = true
        let accounts = AccountService(context: memory.mainContext)
        let store = RoleStore(context: memory.mainContext, accounts: accounts, notifications: NotificationScheduler())
        store.snapshotFrozen = true
        store.durationMemory = .inMemory()   // never the user's preferences
        store.ticketMemory = .inMemory()
        return Env(container: memory, accounts: accounts, store: store)
    }

    static func run(_ env: Env) {
        guard let directory else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                NSApp.terminate(nil)
            }
            try? await Task.sleep(for: .milliseconds(500))
            for scheme in [ColorScheme.dark, .light] {
                let suffix = scheme == .dark ? "dark" : "light"
                // Default state: Permanent group collapsed, every other section expanded.
                defaults.removePersistentDomain(forName: suiteName)
                render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "panel-\(suffix).png"), env: env)
                PreferenceKeys.all.filter { $0.hasPrefix("panel.") }.forEach { defaults.set(true, forKey: $0) }
                render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "panel-expanded-\(suffix).png"), env: env)
                for item in SidebarItem.allCases {
                    render(MainWindow(snapshot: item), size: NSSize(width: 1100, height: 720), scheme: scheme,
                           to: directory.appending(path: "window-\(item.rawValue.lowercased())-\(suffix).png"),
                           env: env)
                }
                defaults.removePersistentDomain(forName: suiteName)
                for (name, query) in [("search", "reader"), ("search-none", "nothing like this")] {
                    render(MenuBarPanel(initialQuery: query), size: NSSize(width: Theme.panelWidth, height: 1400),
                           scheme: scheme, to: directory.appending(path: "panel-\(name)-\(suffix).png"), env: env)
                }
                render(MenuBarLabel(), size: NSSize(width: 160, height: 24), scheme: scheme,
                       to: directory.appending(path: "menubar-\(suffix).png"), env: env)
            }
            // A request waiting for approval and a second tenant (account menu), for these renders only.
            let added = addPendingAndSecondAccount(context: env.container.mainContext)
            for scheme in [ColorScheme.dark, .light] {
                let suffix = scheme == .dark ? "dark" : "light"
                defaults.removePersistentDomain(forName: suiteName)
                render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "panel-pending-\(suffix).png"), env: env)
                render(MenuBarLabel(), size: NSSize(width: 160, height: 24), scheme: scheme,
                       to: directory.appending(path: "menubar-pending-\(suffix).png"), env: env)
            }
            renderOffline(env: env, directory: directory, defaults: defaults)
            added.forEach { env.container.mainContext.delete($0) }
            // Deleted and saved first: the pending fixture would otherwise block the ticket sheet.
            try? env.container.mainContext.save()
            renderSheets(env: env, directory: directory, defaults: defaults)
            renderKeyboard(env: env, directory: directory, defaults: defaults)
            renderContrast(env: env, directory: directory, defaults: defaults)
            renderOnboarding(env: env, directory: directory)
        }
    }

    /// Offline, next expiry in hours, 1 pending: the longest hero line.
    private static func renderOffline(env: Env, directory: URL, defaults: UserDefaults) {
        let context = env.container.mainContext
        let activations = ((try? context.fetch(FetchDescriptor<ActiveAssignment>())) ?? []).filter { $0.endAt != nil }
        activations.forEach { $0.endAt = $0.endAt.map { $0 + 3 * 3600 } }
        let msal = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).first { $0.mode == .msal }
        if let msal { env.store.snapshotOffline(msal, lastOnline: .now - 12 * 60) }
        for scheme in [ColorScheme.dark, .light] {
            defaults.removePersistentDomain(forName: suiteName)
            render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                   to: directory.appending(path: "panel-offline-\(scheme == .dark ? "dark" : "light").png"), env: env)
        }
        if let msal { env.store.snapshotOffline(msal, lastOnline: nil) }
        activations.forEach { $0.endAt = $0.endAt.map { $0 - 3 * 3600 } }
    }

    /// `Security Reader` waiting for an approver, and an account of another tenant. Returns what to delete afterwards.
    private static func addPendingAndSecondAccount(context: ModelContext) -> [any PersistentModel] {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard let msal = accounts.first(where: { $0.mode == .msal }) else { return [] }
        let record = ActivationRecord(account: msal, eligibleRoleId: "\(msal.id.uuidString)|e-secreader",
                                      roleName: "Security Reader", scopeName: "Directory", source: .entraRole,
                                      action: .activate, requestedDuration: "PT1H")
        record.status = .pendingApproval
        record.remoteRequestId = "req-secreader"
        record.sentAt = .now - 4 * 60
        let other = Account(mode: .azureCLI, upn: "v.admin@fabrikam.com", objectId: "oid-2", tenantId: "tenant-fabrikam",
                            tenantName: "Fabrikam", sortOrder: 2)
        other.lastRefreshAt = .now
        context.insert(record)
        context.insert(other)
        try? context.save()
        return [record, other]
    }

    // MARK: Rendering

    static func render(_ view: some View, size: NSSize, scheme: ColorScheme, to url: URL, env: Env) {
        let container = env.container, accounts = env.accounts, store = env.store
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let root = view
            .environment(accounts)
            .environment(store)
            .modelContainer(container)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)   // an offscreen window is never key: draw controls active
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.6)
        let fitting = hosting.fittingSize
        if fitting.height > 0, fitting.height < size.height, size.width == Theme.panelWidth {
            window.setContentSize(NSSize(width: size.width, height: fitting.height))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.3)
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

extension SnapshotRunner {
    /// Activation Sheet states, after the other renders (the pending request would show in History and the panel):
    /// a remembered duration, the 1 h default with a missing justification, a policy under one hour with a ticket, and
    /// a request already waiting. Then the grouped favorite sheet: a ticket role and a role without a justification,
    /// with the tenant's ticket system and a ticket number used an hour ago prefilled.
    private static func renderSheets(env: Env, directory: URL, defaults: UserDefaults) {
        let context = env.container.mainContext
        let msal = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).first { $0.mode == .msal }
        guard let msal else { return }
        func role(_ remoteId: String, _ policy: RolePolicy, justification: String? = nil) -> EligibleRole? {
            let role = env.store.eligibleRole(id: "\(msal.id.uuidString)|\(remoteId)")
            role?.policy = policy   // read: the sheet never asks Azure
            role?.lastJustification = justification
            return role
        }
        let remembered = role("e-kvadmin", RolePolicy(maxDuration: "PT8H"), justification: "Rotate the TLS certificate")
        let fresh = role("e-globalreader", RolePolicy(maxDuration: "PT8H"))
        let ticket = role("e-secreader", RolePolicy(maxDuration: "PT30M", requiresTicket: true),
                          justification: "Review the sign-in alerts")
        let waiting = role("e-ops", RolePolicy(maxDuration: "PT4H", requiresApproval: true), justification: "Hotfix")
        if let waiting {
            let record = ActivationRecord(account: msal, eligibleRoleId: waiting.id, roleName: waiting.roleName,
                                          scopeName: waiting.scopeName, source: waiting.source, action: .activate,
                                          requestedDuration: "PT1H", justification: "Hotfix")
            record.status = .pendingApproval
            record.remoteRequestId = "req-ops"
            context.insert(record)
        }
        // A ticket used an hour ago for the Security Reader role: the same incident, so both sheets prefill it.
        if let ticket {
            env.store.rememberTicket(ActivationInput(duration: "PT30M", justification: "", ticketNumber: "INC0042137",
                                                     ticketSystem: "ServiceNow"), for: ticket, at: .now - 3600)
        }
        try? context.save()
        let sheets = [("remembered", remembered), ("justification", fresh), ("ticket", ticket), ("pending", waiting)]
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            defaults.removePersistentDomain(forName: suiteName)
            if let remembered { env.store.rememberDuration("PT2H15M", for: remembered) }
            for (name, role) in sheets {
                guard let role else { continue }
                render(ActivationSheet(role: role) {}, size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "sheet-\(name)-\(suffix).png"), env: env)
            }
            // Favorite editor with its per-role duration stepper.
            let favorite = ((try? context.fetch(FetchDescriptor<Favorite>())) ?? []).first { $0.name == "Morning deploy" }
            render(FavoritesView(initialSelection: favorite?.id), size: NSSize(width: 900, height: 520), scheme: scheme,
                   to: directory.appending(path: "favorite-editor-\(suffix).png"), env: env)
        }
        renderFavoriteSheets(env: env, directory: directory, defaults: defaults, roles: [ticket, fresh].compactMap { $0 })
    }

    /// Grouped favorite sheet: a ticket role and a role without a justification in one tenant (prefilled), then the
    /// same with a ticket role of a second tenant (one empty ticket per tenant). The favorites are never saved.
    private static func renderFavoriteSheets(env: Env, directory: URL, defaults: UserDefaults, roles: [EligibleRole]) {
        let context = env.container.mainContext
        let other = Account(mode: .azureCLI, upn: "v.admin@fabrikam.com", objectId: "oid-2", tenantId: "tenant-fabrikam",
                            tenantName: "Fabrikam", sortOrder: 9)
        let foreign = EligibleRole(id: "f-secreader", account: other, source: .entraRole, roleDefinitionId: "rd-secreader",
                                   roleName: "Security Reader", scope: "/", scopeName: "Directory", scopeType: "directory")
        foreign.policy = RolePolicy(maxDuration: "PT1H", requiresTicket: true)
        context.insert(other)
        context.insert(foreign)
        func request(_ name: String, _ list: [EligibleRole]) -> FavoriteRunRequest {
            let items = list.map { FavoriteItem(eligibleRoleId: $0.id, duration: "PT30M") }
            return FavoriteRunRequest(favorite: Favorite(name: name, items: items),
                                      roles: zip(items, list).map { (item: $0, role: $1) })
        }
        let requests = [("ticket", request("Incident response", roles)),
                        ("tenants", request("Incident response", roles + [foreign]))]
        for scheme in [ColorScheme.dark, .light] {
            defaults.removePersistentDomain(forName: suiteName)
            for (name, request) in requests {
                render(FavoriteActivationSheet(request: request) {}, size: NSSize(width: Theme.panelWidth, height: 1400),
                       scheme: scheme, to: directory.appending(path: "sheet-favorite-\(name)-\(scheme == .dark ? "dark" : "light").png"),
                       env: env)
            }
        }
        context.delete(foreign)
        context.delete(other)
        try? context.save()
    }

    /// Palette (a search, second row selected) and the Settings › General shortcut row at its default ⌃⌥P.
    private static func renderKeyboard(env: Env, directory: URL, defaults: UserDefaults) {
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            defaults.removePersistentDomain(forName: suiteName)
            // « reader »: the active Reader ranks first (its name starts with the word); index 0 shows the active-row
            // hint, index 1 an eligible role.
            for (name, index) in [("palette-active", 0), ("palette-search", 1)] {
                render(QuickPaletteView(initialQuery: "reader", initialSelection: index) {},
                       size: NSSize(width: QuickPaletteView.width, height: 416), scheme: scheme,
                       to: directory.appending(path: "\(name)-\(suffix).png"), env: env)
            }
            render(Form { Section("Keyboard") { QuickActivateShortcutRow() } }.formStyle(.grouped),
                   size: NSSize(width: 620, height: 150), scheme: scheme,
                   to: directory.appending(path: "settings-shortcut-\(suffix).png"), env: env)
            render(GeneralSettingsView(), size: NSSize(width: 620, height: 300), scheme: scheme,
                   to: directory.appending(path: "settings-general-\(suffix).png"), env: env)
        }
    }
}
#endif
