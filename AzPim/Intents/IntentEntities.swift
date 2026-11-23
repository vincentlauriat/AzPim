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

    /// Text built at run time (already localized): never looked up again as a catalog key.
    static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: text)
    }

    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(resource(text))
    }

    /// Asks Shortcuts to confirm `text`; Cancel throws, so nothing is sent. True once confirmed.
    static func confirm(_ intent: some AppIntent, _ text: String) async throws -> Bool {
        if #available(macOS 15.0, *) {
            try await intent.requestConfirmation(actionName: .go, dialog: dialog(text))
        } else {
            try await intent.requestConfirmation(result: .result(dialog: dialog(text)))
        }
        return true
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
