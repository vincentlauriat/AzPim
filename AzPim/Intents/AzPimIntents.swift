import AppIntents
import AzPimCore
import Foundation

// Shortcuts actions (1.0 item 4), also the base for Raycast and Alfred (`shortcuts run`). The logic lives in
// `RoleStore+Intents`; these types only bridge parameters, prompts and confirmations. Activating obeys the same setting
// as `azpim://activate`, and every request is confirmed with what will be sent.

struct ActivateRoleIntent: AppIntent {
    static let title: LocalizedStringResource = "Activate Role"
    static let description = IntentDescription("""
        Activates an eligible Azure role after you confirm its scope, account and duration. \
        Asks for a justification or a ticket when the role's policy requires one.
        """)

    @Parameter(title: "Role")
    var role: RoleEntity

    @Parameter(title: "Duration (minutes)", description: "Default: the last duration used for this role, else 1 hour.",
               inclusiveRange: (5, 1440))
    var minutes: Int?

    @Parameter(title: "Justification")
    var justification: String?

    @Parameter(title: "Ticket system", description: "Default: the one last used in the role's tenant.")
    var ticketSystem: String?

    @Parameter(title: "Ticket number")
    var ticket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$role)") {
            \.$minutes
            \.$justification
            \.$ticketSystem
            \.$ticket
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        let request = RoleStore.IntentRequest(roleId: role.id, minutes: minutes, justification: justification,
                                              ticketSystem: ticketSystem, ticket: ticket)
        return try await IntentSupport.store().intentActivate(
            request, allowed: RoleStore.intentActivationAllowed,
            ask: { try await IntentSupport.ask($0, justification: $justification, system: $ticketSystem, ticket: $ticket) },
            confirm: { try await IntentSupport.confirm(self, $0, on: $role, showing: role) })
    }
}

struct RunFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Favorite"
    static let description = IntentDescription("""
        Activates every role of an AzPim favorite after you confirm what each one will send. \
        Asks for a justification or a ticket when a role's policy requires one.
        """)

    @Parameter(title: "Favorite")
    var favorite: FavoriteEntity

    @Parameter(title: "Justification", description: "Replaces the justification of every role.")
    var justification: String?

    @Parameter(title: "Ticket system", description: "Used when the ticket roles are all in one tenant.")
    var ticketSystem: String?

    @Parameter(title: "Ticket number", description: "Used when the ticket roles are all in one tenant.")
    var ticket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$favorite)") {
            \.$justification
            \.$ticketSystem
            \.$ticket
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        let request = RoleStore.IntentFavoriteRequest(id: favorite.id, justification: justification,
                                                      ticketSystem: ticketSystem, ticket: ticket)
        return try await IntentSupport.store().intentRunFavorite(
            request, allowed: RoleStore.intentActivationAllowed,
            ask: { try await IntentSupport.ask($0, justification: $justification, system: $ticketSystem, ticket: $ticket) },
            confirm: { try await IntentSupport.confirm(self, $0, on: $favorite, showing: favorite) })
    }
}

struct ListActiveRolesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Active Roles"
    static let description = IntentDescription("Lists the Azure roles active now, with their scope and the time left.")

    func perform() async throws -> some IntentResult & ReturnsValue<[RoleEntity]> & ProvidesDialog {
        let (roles, text) = try await run()
        return .result(value: roles, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> ([RoleEntity], String) {
        let store = try IntentSupport.store()
        try await store.intentReady()
        let active = store.intentRoles().filter(\.active)
        return (active.map(RoleEntity.init), store.intentActiveSummary(active))
    }
}

struct DeactivateAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Deactivate All Roles"
    static let description = IntentDescription("""
        Deactivates every active Azure role, or only the roles given, after you confirm the list.
        """)

    @Parameter(title: "Roles", description: "Not set: every active role. An empty list deactivates nothing.")
    var roles: [RoleEntity]?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        let store = try IntentSupport.store()
        let only = roles.map { Set($0.map(\.id)) }
        return try await store.intentDeactivateAll(only: only, confirm: { text, ids in
            // macOS 14 only: the confirmation is asked on the Roles parameter, showing the first role deactivated
            // (the dialog lists them all).
            var shown: RoleEntity?
            if #unavailable(macOS 15.0) {
                shown = store.intentRoles().first { $0.id == ids.first }.map(RoleEntity.init)
            }
            return try await IntentSupport.confirm(self, text, on: $roles, showing: shown)
        })
    }
}

/// Siri and Spotlight phrases (`AppShortcuts.xcstrings` holds the French ones).
struct AzPimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ActivateRoleIntent(), phrases: ["Activate a role with \(.applicationName)",
                                                            "Activate an Azure role with \(.applicationName)"],
                    shortTitle: "Activate Role", systemImageName: "bolt.shield")
        AppShortcut(intent: RunFavoriteIntent(), phrases: ["Run a favorite with \(.applicationName)",
                                                           "Run an \(.applicationName) favorite"],
                    shortTitle: "Run Favorite", systemImageName: "star")
        AppShortcut(intent: ListActiveRolesIntent(), phrases: ["List active roles in \(.applicationName)",
                                                               "Show my active roles in \(.applicationName)"],
                    shortTitle: "Active Roles", systemImageName: "list.bullet")
        AppShortcut(intent: DeactivateAllIntent(), phrases: ["Deactivate all roles in \(.applicationName)"],
                    shortTitle: "Deactivate All", systemImageName: "xmark.shield")
    }
}
