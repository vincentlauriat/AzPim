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
    private static let suiteName = "fr.vincentlauriat.azpim.snapshot"

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
        addFixtures(context: context)
        try? context.save()
        let accounts = AccountService(context: context)
        let store = RoleStore(context: context, accounts: accounts, notifications: NotificationScheduler())
        store.snapshotFrozen = true   // a window becoming key must not refresh the fixtures
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
                PreferenceKeys.all.forEach { defaults.set(true, forKey: $0) }
                render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "panel-expanded-\(suffix).png"), env: env)
                for item in SidebarItem.allCases {
                    render(MainWindow(snapshot: item), size: NSSize(width: 1100, height: 720), scheme: scheme,
                           to: directory.appending(path: "window-\(item.rawValue.lowercased())-\(suffix).png"),
                           env: env)
                }
            }
        }
    }

    // MARK: Fixtures

    /// One person signed in twice (Azure CLI and Microsoft, same tenant and UPN in another case), Azure roles held by
    /// both, Entra roles of which one is activated and also assigned permanently through a group, one held only
    /// permanently, and PIM groups. Before the dedup this rendered every Azure role twice and both Entra roles twice.
    private static func addFixtures(context: ModelContext) {
        let cli = Account(mode: .azureCLI, upn: "V.Admin@Contoso.com", objectId: "oid-1", tenantId: "TENANT-CONTOSO",
                          tenantName: "Contoso", sortOrder: 0)
        let msal = Account(mode: .msal, upn: "v.admin@contoso.com", objectId: "oid-1", tenantId: "tenant-contoso",
                           tenantName: "Contoso", sortOrder: 1)
        msal.directoryAccess = .enabled
        for account in [cli, msal] {
            account.lastRefreshAt = .now
            context.insert(account)
        }
        // Azure resource roles, cached under both accounts (the CLI copies must not show).
        for account in [cli, msal] {
            let fixtures = Fixtures(context: context, account: account)
            let reader = fixtures.eligible("e-reader", .azureResource, "Reader", "/providers/mg/root",
                                           "Tenant Root Group")
            let contributor = fixtures.eligible("e-contrib", .azureResource, "Contributor", "/subs/s1/rg/app-prod",
                                                "rg-app-prod-weu001")
            _ = fixtures.eligible("e-kvadmin", .azureResource, "Key Vault Administrator", "/subs/s1/kv/app-prod",
                                  "kv-app-prod-weu001")
            fixtures.assignment("a-reader", .azureResource, "Reader", "/providers/mg/root", "Tenant Root Group",
                                started: 18 * 60, ends: 42 * 60, role: reader)
            fixtures.assignment("a-contrib", .azureResource, "Contributor", "/subs/s1/rg/app-prod",
                                "rg-app-prod-weu001", started: 7 * 3600, ends: 3 * 3600 + 16 * 60, role: contributor)
            fixtures.assignment("p-kvso", .azureResource, "Key Vault Secrets Officer", "/subs/s1/kv/app-dev",
                                "kv-app-dev-weu001")
            if account === msal { addEntraAndGroups(fixtures) }
        }
        let favoriteRole = "\(cli.id.uuidString)|e-contrib"   // saved on the CLI account: resolves onto the MSAL one
        context.insert(Favorite(name: "Morning deploy", items: [FavoriteItem(eligibleRoleId: favoriteRole, duration: "PT4H")]))
        context.insert(Favorite(name: "Audit", items: [FavoriteItem(eligibleRoleId: "\(msal.id.uuidString)|e-reader",
                                                                    duration: "PT1H")], sortOrder: 1))
        addHistory(account: msal, context: context)
    }

    private static func addEntraAndGroups(_ fixtures: Fixtures) {
        let license = fixtures.eligible("e-license", .entraRole, "License Administrator", "/", "Directory")
        _ = fixtures.eligible("e-useradmin", .entraRole, "User Administrator", "/", "Directory")
        _ = fixtures.eligible("e-globalreader", .entraRole, "Global Reader", "/", "Directory")
        _ = fixtures.eligible("e-secreader", .entraRole, "Security Reader", "/", "Directory")
        // Activated through PIM and also assigned permanently via a group: one row, "also permanent".
        fixtures.assignment("a-license", .entraRole, "License Administrator", "/", "Directory",
                            started: 55 * 60, ends: 65 * 60, role: license)
        fixtures.assignment("p-license", .entraRole, "License Administrator", "/", "Directory")
        // Held permanently only: shown under Permanent, not offered as eligible.
        fixtures.assignment("p-useradmin", .entraRole, "User Administrator", "/", "Directory")
        let sql = fixtures.eligible("e-sql", .pimGroup, "Member", "g-sql", "sg-pim-sql-admins")
        _ = fixtures.eligible("e-ops", .pimGroup, "Member", "g-ops", "sg-pim-prod-operators")
        _ = fixtures.eligible("e-glass", .pimGroup, "Owner", "g-glass", "sg-pim-break-glass")
        fixtures.assignment("a-sql", .pimGroup, "Member", "g-sql", "sg-pim-sql-admins",
                            started: 35 * 60, ends: 25 * 60, role: sql)
    }

    private struct Fixtures {
        let context: ModelContext
        let account: Account

        func eligible(_ id: String, _ source: RoleSource, _ name: String, _ scope: String,
                      _ scopeName: String) -> EligibleRole {
            let role = EligibleRole(id: id, account: account, source: source, roleDefinitionId: "def-\(name)", roleName: name,
                                    scope: scope, scopeName: scopeName, scopeType: source == .entraRole ? "directory" : "scope")
            context.insert(role)
            return role
        }

        /// An activation when `ends` is given (seconds from now), else a permanent assignment.
        func assignment(_ id: String, _ source: RoleSource, _ name: String, _ scope: String,
                        _ scopeName: String, started: TimeInterval = 86_400, ends: TimeInterval? = nil,
                        role: EligibleRole? = nil) {
            context.insert(ActiveAssignment(id: id, account: account, source: source, roleName: name, scope: scope,
                                            scopeName: scopeName, assignmentType: ends == nil ? .assigned : .activated,
                                            startAt: .now - started, endAt: ends.map { .now + $0 }, eligibleRole: role))
        }
    }

    private static func addHistory(account: Account, context: ModelContext) {
        struct Sample {
            let roleId: String, name: String, scope: String, action: ActivationAction, ago: TimeInterval
            let justification: String, took: TimeInterval
        }
        let prefix = account.id.uuidString + "|"
        let samples = [
            Sample(roleId: "e-reader", name: "Reader", scope: "Tenant Root Group", action: .activate, ago: 18 * 60,
                   justification: "Audit of the tenant root policies", took: 14),
            Sample(roleId: "e-license", name: "License Administrator", scope: "Directory", action: .activate, ago: 55 * 60,
                   justification: "Assign licenses to the new hires", took: 9),
            Sample(roleId: "e-contrib", name: "Contributor", scope: "rg-app-prod-weu001", action: .activate, ago: 7 * 3600,
                   justification: "Deploy release 2.4 to production", took: 21),
            Sample(roleId: "e-reader", name: "Reader", scope: "Tenant Root Group", action: .deactivate, ago: 26 * 3600,
                   justification: "", took: 0)
        ]
        for sample in samples {
            let record = ActivationRecord(account: account, eligibleRoleId: prefix + sample.roleId, roleName: sample.name,
                                          scopeName: sample.scope, source: .azureResource, action: sample.action,
                                          requestedDuration: sample.action == .activate ? "PT1H" : nil,
                                          justification: sample.justification.isEmpty ? nil : sample.justification,
                                          panelOpenedAt: sample.action == .activate ? .now - sample.ago - sample.took : nil)
            record.sentAt = .now - sample.ago
            record.status = .provisioned
            record.completedAt = .now - sample.ago + max(sample.took - 8, 1)
            context.insert(record)
        }
    }

    // MARK: Rendering

    private static func render(_ view: some View, size: NSSize, scheme: ColorScheme, to url: URL, env: Env) {
        let container = env.container, accounts = env.accounts, store = env.store
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let root = view
            .environment(accounts)
            .environment(store)
            .modelContainer(container)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
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
#endif
