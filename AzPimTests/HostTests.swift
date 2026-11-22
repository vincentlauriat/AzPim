@testable import AzPim
import AzPimCore
import Testing

/// The bundle runs inside the app, on the test-host branch of `AzPimApp.init` (in-memory store).
@MainActor
struct HostTests {
    /// Fails if `XCTestConfigurationFilePath` detection breaks: the app would then have taken the production path,
    /// which assigns `DeepLinkHandler.store` and starts refreshing the user's real store.
    @Test func appTookTheTestHostBranch() {
        #expect(SnapshotRunner.isTestHost)
        #expect(DeepLinkHandler.store == nil)
    }

    @Test func hostRunsOnAnInMemoryStore() throws {
        let container = try AzPimStore.makeContainer(inMemory: true)
        let settings = try AzPimStore.settings(in: container.mainContext)
        #expect(settings.refreshIntervalMinutes == 5)
    }
}
