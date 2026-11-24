import AppIntents
import Foundation

/// Extend button of the Live Activity (lock screen, expanded Dynamic Island). A `LiveActivityIntent` runs in the app's
/// process, launched in the background if needed, so the widget extension only draws the button: it compiles this
/// type but never runs it, and holds no store, no token and no network code. The app sets `handler` at launch
/// (`AzPimMobileApp`); without it (extension, store not created) the intent fails with a clear message.
/// Extend changes privileges: the device must be unlocked first, as for the expiry notification's Extend.
struct ExtendRoleActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Extend Role"
    static let description = IntentDescription("Extends the activation shown in the Live Activity.")
    static let isDiscoverable = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    /// Runs the store's Extend for an eligible role id; throws when the store cannot run it.
    @MainActor static var handler: ((String) async throws -> Void)?

    @Parameter(title: "Role")
    var eligibleRoleId: String

    init() {}

    init(eligibleRoleId: String) {
        self.eligibleRoleId = eligibleRoleId
    }

    func perform() async throws -> some IntentResult {
        try await run()
        return .result()
    }

    @MainActor
    private func run() async throws {
        guard let handler = Self.handler else { throw NotReady() }
        try await handler(eligibleRoleId)
    }

    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "AzPim isn't ready yet. Open AzPim, then try again." }
    }
}
