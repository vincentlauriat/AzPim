import Foundation
import SwiftData

/// Versioned schema (BackendSchema › Migrations). Add `AzPimSchemaV2` + a migration stage for changes.
public enum AzPimSchemaV1: VersionedSchema {
    // Computed, not stored: Schema.Version is not Sendable in the macOS 15 SDK (Swift 6.1 rejects a stored static).
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Account.self, EligibleRole.self, ActiveAssignment.self, Favorite.self, ActivationRecord.self, AppSettings.self]
    }
}

public enum AzPimMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AzPimSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum AzPimStore {
    /// Default on-disk location: ~/Library/Application Support/AzPim/AzPim.store
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "AzPim", directoryHint: .isDirectory)
            .appending(path: "AzPim.store")
    }

    /// Store of the 0.9.x releases, shipped as AzurePim: ~/Library/Application Support/AzurePim/AzurePim.store
    public static var legacyURL: URL {
        URL.applicationSupportDirectory.appending(path: "AzurePim", directoryHint: .isDirectory)
            .appending(path: "AzurePim.store")
    }

    /// One-time copy of the AzurePim store (and its `-wal` / `-shm` sidecars) to the AzPim location, before the
    /// container opens. Copies, never moves or deletes: the old app and its data stay as they were. No-op when the
    /// new store already exists or there is no old one. Returns true when it copied.
    @discardableResult
    public static func migrateLegacyStore(from old: URL = legacyURL, to new: URL = defaultURL) throws -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path), files.fileExists(atPath: old.path) else { return false }
        try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        func sibling(_ store: URL, _ suffix: String) -> URL {
            store.deletingLastPathComponent().appending(path: store.lastPathComponent + suffix)
        }
        var copied: [URL] = []
        do {
            // Sidecars first, the store last: the new store file is the "already migrated" marker.
            for suffix in ["-wal", "-shm", ""] {
                let source = sibling(old, suffix)
                guard files.fileExists(atPath: source.path) else { continue }
                let target = sibling(new, suffix)
                // A sidecar without its store is a leftover, never live data.
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: source, to: target)
                copied.append(target)
            }
        } catch {
            // Leave no half-copied store behind: the next launch tries again.
            copied.forEach { try? files.removeItem(at: $0) }
            throw error
        }
        return true
    }

    public static func makeContainer(inMemory: Bool = false, url: URL = defaultURL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AzPimSchemaV1.self)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Owner-only folder: the store lists the user's privileged roles (security review M3).
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            config = ModelConfiguration(schema: schema, url: url)
        }
        return try ModelContainer(for: schema, migrationPlan: AzPimMigrationPlan.self, configurations: config)
    }

    /// Seed: one AppSettings row (BackendSchema › Seed data). Returns the existing or new row.
    @discardableResult
    public static func settings(in context: ModelContext) throws -> AppSettings {
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first { return existing }
        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        return settings
    }
}
