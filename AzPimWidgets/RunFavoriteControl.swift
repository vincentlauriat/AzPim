import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action button control « Run Favorite » (iOS 18, 2.0 step 4c). Its button opens
/// AzPim on the favorite chooser (`OpenFavoritesIntent`), where a favorite runs only after its confirmation sheet.
/// Not configurable: the extension cannot list favorites (no store, no App Group).
@available(iOS 18.0, *)
struct RunFavoriteControl: ControlWidget {
    static let kind = "fr.vincentlauriat.azpim.ios.run-favorite"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenFavoritesIntent()) {
                Label("Run Favorite", systemImage: "star.fill")
            }
        }
        .displayName("Run Favorite")
        .description("Opens AzPim on your favorites. Nothing is activated until you confirm.")
    }
}
