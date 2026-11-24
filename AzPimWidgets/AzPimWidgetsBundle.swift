import SwiftUI
import WidgetKit

/// AzPim's widget extension: the Live Activity of the activated role that ends first (2.0 step 4a). Widgets (4b) come
/// later. The extension only draws: no store, no token, no network call.
@main
struct AzPimWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RoleLiveActivity()
    }
}
