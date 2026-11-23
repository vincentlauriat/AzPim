import AppIntents
import AzPimCore
import Foundation
import SwiftData

/// Glue between the App Intents runtime and the running app. Intents run in the AzPim process (the menu bar app is
/// long-running; macOS launches it when a shortcut needs it and it is not running), on the store `AzPimApp.init`
/// gives `DeepLinkHandler`. No store (test host, snapshots): a clear error, never a second store.
enum IntentSupport {
    @MainActor
    static func store() throws -> RoleStore {
        guard let store = DeepLinkHandler.store else {
            throw RoleStore.IntentFailure(message: String(localized: "AzPim isn't ready yet. Open AzPim, then try again."))
        }
        return store
    }

    /// Text built at run time (already localized, may hold user content such as a justification): the argument of a
    /// `%@` key, never a key itself, so a `%` typed by the user is never read as a format.
    static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource("\(text)")
    }

    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(resource(text))
    }

    /// Asks Shortcuts for a field the policy requires, through the action's own parameter.
    static func ask(_ field: RoleStore.IntentField, justification: IntentParameter<String?>,
                    system: IntentParameter<String?>, ticket: IntentParameter<String?>) async throws -> String {
        switch field {
        case .justification:
            try await justification.requestValue("The policy requires a justification. Why do you need this role?")
        case .ticketSystem(let tenant?):
            try await system.requestValue("A role in \(tenant) requires a ticket. Which ticket system?")
        case .ticketSystem(nil):
            try await system.requestValue("The policy requires a ticket. Which ticket system?")
        case .ticketNumber(let tenant?):
            try await ticket.requestValue("Ticket number for \(tenant)?")
        case .ticketNumber(nil):
            try await ticket.requestValue("The policy requires a ticket number. Which ticket?")
        }
    }

    /// Asks Shortcuts to confirm `text`; Cancel throws, so nothing is sent. True once confirmed. macOS 14 has no
    /// non-deprecated intent-level confirmation with a dialog: there, the confirmation is asked on one of the action's
    /// parameters (`parameter`, showing `value`), with the same text; without a value nothing is confirmed.
    static func confirm<Value>(_ intent: some AppIntent, _ text: String, on parameter: IntentParameter<Value>,
                               showing value: Value.ValueType?) async throws -> Bool {
        if #available(macOS 15.0, *) {
            try await intent.requestConfirmation(actionName: .go, dialog: dialog(text))
            return true
        }
        guard let value else { return false }
        return try await parameter.requestConfirmation(for: value, dialog: dialog(text))
    }
}

extension RoleStore.IntentFailure: CustomLocalizedStringResourceConvertible, LocalizedError {
    var localizedStringResource: LocalizedStringResource { IntentSupport.resource(message) }
    var errorDescription: String? { message }
}

// MARK: - Role

/// An eligible role, or one active now (same id: the eligible role's local id).
struct RoleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Azure role" }
    static var defaultQuery: RoleEntityQuery { RoleEntityQuery() }

    let id: String
    let name: String
    let scope: String
    let account: String
    let active: Bool
    let endAt: Date?

    init(_ role: RoleStore.IntentRole) {
        id = role.id
        name = role.name
        scope = role.scope
        account = role.account
        active = role.active
        endAt = role.endAt
    }

    var displayRepresentation: DisplayRepresentation {
        let line = active ? IntentSummary.activeLine(name: name, scope: scope, endAt: endAt) : "\(scope) · \(account)"
        return DisplayRepresentation(title: IntentSupport.resource(name), subtitle: IntentSupport.resource(line))
    }
}

struct RoleEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RoleEntity] {
        try await MainActor.run {
            let store = try IntentSupport.store()
            let listed = Dictionary(store.intentRoles().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // A role listed by an earlier run of the shortcut: found again by id, superseded accounts resolved.
            return identifiers.compactMap { id in
                listed[id] ?? store.resolvedRole(id: id).flatMap { listed[$0.id] }
            }.map(RoleEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [RoleEntity] {
        try await MainActor.run { try IntentSupport.store().intentRoles(matching: string).map(RoleEntity.init) }
    }

    func suggestedEntities() async throws -> [RoleEntity] {
        try await MainActor.run { try IntentSupport.store().intentRoles().map(RoleEntity.init) }
    }
}

// MARK: - Favorite

struct FavoriteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "AzPim favorite" }
    static var defaultQuery: FavoriteEntityQuery { FavoriteEntityQuery() }

    let id: UUID
    let name: String
    let roleCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: IntentSupport.resource(name),
                              subtitle: IntentSupport.resource(String(localized: "\(roleCount) roles")))
    }
}

struct FavoriteEntityQuery: EntityStringQuery {
    @MainActor
    private static func all() throws -> [FavoriteEntity] {
        let store = try IntentSupport.store()
        let favorites = (try? store.context.fetch(FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        return favorites.map { FavoriteEntity(id: $0.id, name: $0.name, roleCount: $0.items.count) }
    }

    func entities(for identifiers: [UUID]) async throws -> [FavoriteEntity] {
        try await MainActor.run { try Self.all().filter { identifiers.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [FavoriteEntity] {
        try await MainActor.run { try Self.all().filter { RoleSearch.matches(string, fields: [$0.name]) } }
    }

    func suggestedEntities() async throws -> [FavoriteEntity] {
        try await MainActor.run { try Self.all() }
    }
}
