@testable import AzPim
import AzPimCore
import Testing

/// The bundle runs inside the app, on the test-host branch of `AzPimApp.init` (in-memory store).
@MainActor
struct HostTests {
    @Test func hostRunsOnAnInMemoryStore() throws {
        let container = try AzPimStore.makeContainer(inMemory: true)
        let settings = try AzPimStore.settings(in: container.mainContext)
        #expect(settings.refreshIntervalMinutes == 5)
    }
}
