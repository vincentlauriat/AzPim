import Foundation
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

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sidecar(_ store: URL, _ suffix: String) -> URL {
        URL(fileURLWithPath: store.path + suffix)
    }

    @Test func defaultPathsPointAtTheAppSupportFolders() {
        #expect(AzPimStore.defaultURL.path.hasSuffix("/Application Support/AzPim/AzPim.store"))
        #expect(AzPimStore.legacyURL.path.hasSuffix("/Application Support/AzurePim/AzurePim.store"))
    }

    @Test func copiesStoreAndSidecarsUnderTheNewName() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("db", to: old)
        try write("wal", to: sidecar(old, "-wal"))
        try write("shm", to: sidecar(old, "-shm"))

        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new))

        #expect(try read(new) == "db")
        #expect(try read(sidecar(new, "-wal")) == "wal")
        #expect(try read(sidecar(new, "-shm")) == "shm")
        // Copied, not moved.
        #expect(try read(old) == "db")
        #expect(FileManager.default.fileExists(atPath: sidecar(old, "-wal").path))
        let folder = try FileManager.default.attributesOfItem(atPath: new.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Second launch: nothing to do.
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
    }

    @Test func copiesAStoreWithoutSidecars() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("db", to: old)
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new))
        #expect(try read(new) == "db")
        #expect(!FileManager.default.fileExists(atPath: sidecar(new, "-wal").path))
    }

    @Test func neverOverwritesAnExistingNewStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old", to: old)
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("new", to: new)
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
        #expect(try read(new) == "new")
    }

    @Test func doesNothingWithoutAnOldStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AzPimStore.migrateLegacyStore(from: old, to: new) == false)
        #expect(!FileManager.default.fileExists(atPath: new.deletingLastPathComponent().path))
    }
}
