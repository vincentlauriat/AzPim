import Foundation
import SQLite3
import SwiftData
import Testing
@testable import AzPimCore

/// One-time copy of the AzurePim (0.9.x) store to the AzPim location.
struct StoreMigrationTests {
    let root: URL
    let old: URL
    let new: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "azpim-migration-\(UUID().uuidString)")
        old = root.appending(path: "AzurePim/AzurePim.store")
        new = root.appending(path: "AzPim/AzPim.store")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Runs SQL on an open handle; fails the test on error.
    private func exec(_ db: OpaquePointer?, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
    }

    private func readInt(_ url: URL, _ sql: String) -> Int? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test func defaultPathsPointAtTheAppSupportFolders() {
        #expect(AzPimStore.defaultURL.path.hasSuffix("/Application Support/AzPim/AzPim.store"))
        #expect(AzPimStore.legacyURL.path.hasSuffix("/Application Support/AzurePim/AzurePim.store"))
    }

    /// The renamed copy must still open as a SwiftData store, with its rows.
    @MainActor @Test func copiedStoreOpensWithItsRows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let legacy = try AzPimStore.makeContainer(url: old)
            let settings = try AzPimStore.settings(in: legacy.mainContext)
            settings.historyRetentionDays = 30
            try legacy.mainContext.save()
        }
        #expect(AzPimStore.needsLegacyMigration(from: old, to: new))
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new))
        #expect(!AzPimStore.needsLegacyMigration(from: old, to: new))
        let migrated = try AzPimStore.makeContainer(url: new)
        let rows = try migrated.mainContext.fetch(FetchDescriptor<AppSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.historyRetentionDays == 30)
        // Second launch: nothing to do.
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
    }

    /// Rows still only in the write-ahead log (the old store is open, nothing checkpointed) are in the copy, and
    /// the old files are left as they were.
    @Test func snapshotIncludesTheWriteAheadLog() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var writer: OpaquePointer?
        defer { sqlite3_close(writer) }
        #expect(sqlite3_open(old.path, &writer) == SQLITE_OK)
        exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        exec(writer, "CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (42);")
        let wal = AzPimStore.storeFiles(old)[1]
        #expect(exists(wal))
        let walSize = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int

        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new))

        #expect(readInt(new, "SELECT x FROM t") == 42)
        #expect(try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int == walSize)
        let folder = try FileManager.default.attributesOfItem(atPath: new.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: new.deletingLastPathComponent().path)
        #expect(!leftovers.contains { $0.contains(".migrating") })
    }

    @Test func failedCopyLeavesNoNewStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a database".utf8).write(to: old)
        #expect(throws: StoreMigrationError.self) { try AzPimStore.migrateLegacyStore(from: old, to: new) }
        #expect(!exists(new))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: new.deletingLastPathComponent().path)
        #expect(leftovers.isEmpty)
        // Next launch tries again.
        #expect(AzPimStore.needsLegacyMigration(from: old, to: new))
    }

    @Test func neverOverwritesAnExistingNewStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: old)
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new)
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
        #expect(try String(contentsOf: new, encoding: .utf8) == "new")
    }

    @Test func doesNothingWithoutAnOldStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
        #expect(!exists(new.deletingLastPathComponent()))
    }

    @Test func storeFilesListTheSidecars() {
        #expect(AzPimStore.storeFiles(new).map(\.lastPathComponent) == ["AzPim.store", "AzPim.store-wal", "AzPim.store-shm"])
    }
}
