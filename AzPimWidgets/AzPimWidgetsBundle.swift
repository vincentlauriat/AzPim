import SwiftUI
import WidgetKit

/// AzPim's widget extension: the Live Activity of the activated role that ends first (2.0 step 4a), the Active roles
/// and Favorites widgets (4b), drawn from the snapshot the app writes to the App Group, and, on iOS 18, the Control
/// Center control « Run Favorite » (4c). The extension only draws: no store, no token, no network call.
@main
struct AzPimWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RoleLiveActivity()
        ActiveRolesWidget()
        FavoritesWidget()
        // The deployment target stays iOS 17: `buildLimitedAvailability` (iOS 16.1 SDK and later) takes the control.
        if #available(iOS 18.0, *) {
            RunFavoriteControl()
        }
    }
}
