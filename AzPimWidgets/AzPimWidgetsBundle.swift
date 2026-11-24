import SwiftUI
import WidgetKit

/// AzPim's widget extension: the Live Activity of the activated role that ends first (2.0 step 4a), and the Active
/// roles and Favorites widgets (4b), drawn from the snapshot the app writes to the App Group. The extension only draws:
/// no store, no token, no network call.
@main
struct AzPimWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RoleLiveActivity()
        ActiveRolesWidget()
        FavoritesWidget()
    }
}
