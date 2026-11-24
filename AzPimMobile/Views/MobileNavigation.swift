import AzPimCore
import Observation
import SwiftUI

/// What the user has open: the selected role, the sheets and the deactivate question. Owned by `MobileRootView`,
/// above the compact / regular switch, so folding or unfolding the iPhone Duo (a size-class change) keeps them.
@MainActor
@Observable
final class MobileNavigation {
    /// The selected row (`RoleRow.id`: the eligible role's id, stable across activation and deactivation). Regular
    /// width shows it in the detail column, compact width pushes it on top of the panel.
    var selection: String?
    var activating: EligibleRole?
    var askingFavorite: FavoriteRunRequest?
    var deactivating: ActiveAssignment?
    var showSettings = false
    var showHistory = false
    /// Last Extend result, per eligible role id (shown on the role detail, announced to VoiceOver).
    var extendResult: (roleId: String, text: String)?
    /// Filters of the roles list (regular width).
    var search = ""
    var source: RoleSource?
    var accountId: UUID?
    var state: RoleStateFilter = .all

    init(selection: String? = nil, activating: EligibleRole? = nil, showSettings: Bool = false, showHistory: Bool = false) {
        self.selection = selection
        self.activating = activating
        self.showSettings = showSettings
        self.showHistory = showHistory
    }

    /// Extends the role's activation (`RoleStore.extend`): says it started, then how it ended.
    func extend(_ role: EligibleRole, store: RoleStore) {
        let roleId = role.id
        VoiceOverAnnouncer.post(String(localized: "Extending \(role.displayRoleName)…"))
        extendResult = nil
        Task {
            let text = await store.extend(eligibleRoleId: roleId)
            extendResult = (roleId, text)
            VoiceOverAnnouncer.post(text)
        }
    }
}

/// Compact or regular layout. The size class decides; a window at least 600 pt wide also gets the split view, since
/// Apple has not documented which size class the unfolded iPhone Duo reports (about 669 pt wide unfolded, 466 pt
/// folded, per the simulator's screen sizes).
enum MobileLayout {
    static let splitMinWidth: CGFloat = 600

    static func isRegular(sizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        sizeClass == .regular || width >= splitMinWidth
    }
}
