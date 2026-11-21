import Foundation
import SQLite3
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

    /// True when the AzurePim store exists and the AzPim one does not yet: the next launch copies it.
    public static func needsLegacyMigration(from old: URL = legacyURL, to new: URL = defaultURL) -> Bool {
        let files = FileManager.default
        return !files.fileExists(atPath: new.path) && files.fileExists(atPath: old.path)
    }

    /// The files SQLite keeps for a store: the database, its write-ahead log and its shared-memory index.
    public static func storeFiles(_ store: URL) -> [URL] {
        ["", "-wal", "-shm"].map { store.deletingLastPathComponent().appending(path: store.lastPathComponent + $0) }
    }

    /// One-time copy of the AzurePim store to the AzPim location, before the container opens. A consistent snapshot
    /// through SQLite `VACUUM INTO` (the write-ahead log included), written to a temporary name then renamed, so
    /// the new store only exists once complete. Never moves, deletes or writes the old store. No-op when the new
    /// store already exists or there is no old one. Returns true when it copied.
    @discardableResult
    public static func migrateLegacyStore(from old: URL = legacyURL, to new: URL = defaultURL) throws -> Bool {
        guard needsLegacyMigration(from: old, to: new) else { return false }
        let files = FileManager.default
        try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let partial = new.deletingLastPathComponent().appending(path: new.lastPathComponent + ".migrating")
        let removePartial = { storeFiles(partial).forEach { try? files.removeItem(at: $0) } }
        removePartial()
        do {
            try snapshot(old, to: partial)
            try files.moveItem(at: partial, to: new)
        } catch {
            removePartial()
            throw error
        }
        removePartial()
        return true
    }

    /// Copies the committed state of the SQLite database at `source`, write-ahead log included, into a new
    /// self-contained database at `target` (`VACUUM INTO`). The source is opened read-only: no checkpoint, no write.
    static func snapshot(_ source: URL, to target: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw StoreMigrationError(step: "open \(source.path)", handle: db)
        }
        // Waits out a short lock (a checkpoint by another reader) instead of failing at once.
        sqlite3_busy_timeout(db, 5000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, target.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreMigrationError(step: "copy \(source.path)", handle: db)
        }
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

/// The AzurePim store could not be copied; the message names the step and SQLite's reason.
public struct StoreMigrationError: Error, CustomStringConvertible {
    public let description: String

    init(step: String, handle: OpaquePointer?) {
        let reason = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
        description = "Could not \(step): \(reason)"
    }
}
