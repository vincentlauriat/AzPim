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
        Asks for a justification or a ticket number when the role's policy requires one.
        """)

    @Parameter(title: "Role")
    var role: RoleEntity

    @Parameter(title: "Duration (minutes)", description: "Default: the last duration used for this role, else 1 hour.",
               inclusiveRange: (5, 1440))
    var minutes: Int?

    @Parameter(title: "Justification")
    var justification: String?

    @Parameter(title: "Ticket number")
    var ticket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$role)") {
            \.$minutes
            \.$justification
            \.$ticket
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        let request = RoleStore.IntentRequest(roleId: role.id, minutes: minutes, justification: justification, ticket: ticket)
        return try await IntentSupport.store().intentActivate(
            request, allowed: RoleStore.intentActivationAllowed,
            ask: { field in
                switch field {
                case .justification:
                    try await $justification.requestValue("The policy requires a justification. Why do you need this role?")
                case .ticket:
                    try await $ticket.requestValue("The policy requires a ticket number. Which ticket?")
                }
            },
            confirm: { try await IntentSupport.confirm(self, $0) })
    }
}

struct RunFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Favorite"
    static let description = IntentDescription("""
        Activates every role of an AzPim favorite after you confirm what each one will send.
        """)

    @Parameter(title: "Favorite")
    var favorite: FavoriteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$favorite)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        try await IntentSupport.store().intentRunFavorite(id: favorite.id, allowed: RoleStore.intentActivationAllowed,
                                                          confirm: { try await IntentSupport.confirm(self, $0) })
    }
}

struct ListActiveRolesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Active Roles"
    static let description = IntentDescription("Lists the Azure roles active now, with their scope and the time left.")

    func perform() async throws -> some IntentResult & ReturnsValue<[RoleEntity]> & ProvidesDialog {
        let (roles, text) = try await MainActor.run {
            let store = try IntentSupport.store()
            let active = store.intentRoles().filter(\.active)
            return (active.map(RoleEntity.init), store.intentActiveSummary(active))
        }
        return .result(value: roles, dialog: IntentSupport.dialog(text))
    }
}

struct DeactivateAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Deactivate All Roles"
    static let description = IntentDescription("Deactivates every active Azure role after you confirm the list.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await run()
        return .result(value: text, dialog: IntentSupport.dialog(text))
    }

    @MainActor
    private func run() async throws -> String {
        try await IntentSupport.store().intentDeactivateAll(confirm: { try await IntentSupport.confirm(self, $0) })
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
