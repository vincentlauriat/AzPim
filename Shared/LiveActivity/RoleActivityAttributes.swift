import ActivityKit
import Foundation

/// The Live Activity of the activated role that ends first (iPhone, 2.0 step 4a). Compiled by the app, which starts,
/// updates and ends it from the foreground (`LiveActivityController`), and by the widget extension, which draws it.
/// No push server: nothing updates it while the app is not running; the countdown ticks by itself
/// (`Text(timerInterval:)`) and the system marks it stale at `endAt`.
struct RoleActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// When the activation ends.
        var endAt: Date
        /// Other activations live at the last update (« +2 »).
        var otherActive: Int
    }

    /// Role and scope names as the app shows them (translated when AzPim translates them), never ids.
    var roleName: String
    var scopeName: String
    /// `RoleSource` raw value (azureResource, entraRole, pimGroup): picks the icon.
    var source: String
    /// The eligible role's local id: what Extend acts on.
    var eligibleRoleId: String
}

extension RoleActivityAttributes {
    /// SF Symbol of the role's source, as the app's rows show it.
    var sourceSymbol: String {
        switch source {
        case "entraRole": "person.badge.key"
        case "pimGroup": "person.3"
        default: "cloud"
        }
    }
}
