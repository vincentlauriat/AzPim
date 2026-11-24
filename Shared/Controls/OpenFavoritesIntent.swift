import AppIntents
import Foundation

/// What the Control Center control opens. One case: an `OpenIntent` needs a target, and the control has one place to go.
enum AzPimScreen: String, AppEnum {
    case favorites

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AzPim Screen"
    static let caseDisplayRepresentations: [AzPimScreen: DisplayRepresentation] = [.favorites: "Favorites"]
}

/// Action of the Control Center control « Run Favorite » (iPhone, iOS 18, 2.0 step 4c). An `OpenIntent` opens the app,
/// so `perform` runs in the app's process: the widget extension compiles this type but never runs it (no store, no
/// token, no App Group there). The app sets `handler` at launch (`AzPimMobileApp`): it opens the favorite chooser, and
/// the favorite runs only from its confirmation sheet (`FavoriteActivationSheet`), never from here: like every
/// Shortcuts action since 1.0, nothing is activated without a confirmation.
/// Not configurable with a favorite: the system resolves a control's configuration in the widget extension, which has
/// no access to the favorites (they live in the app's store).
struct OpenFavoritesIntent: OpenIntent {
    static let title: LocalizedStringResource = "Run Favorite"
    static let description = IntentDescription("Opens AzPim on your favorites. Nothing is activated until you confirm.")
    static let isDiscoverable = false

    /// Opens the favorite chooser.
    @MainActor static var handler: (() -> Void)?

    @Parameter(title: "Screen", default: .favorites)
    var target: AzPimScreen

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?()
        return .result()
    }
}
