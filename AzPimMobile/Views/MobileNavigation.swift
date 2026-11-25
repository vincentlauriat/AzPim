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
    /// The favorite chooser, opened by the Control Center control « Run Favorite » (`OpenFavoritesIntent`).
    var choosingFavorite = false
    var deactivating: ActiveAssignment?
    var showSettings = false
    var showHistory = false
    /// The Favorites screen, and the favorite pushed in it (its detail).
    var showFavorites = false
    var favoritePath: [UUID] = []

    /// The Control Center control: SwiftUI shows one sheet at a time, so any open sheet or question is closed first,
    /// otherwise the chooser would not appear (and would pop up later, once that sheet closed).
    func chooseFavorite() {
        dismissPresented()
        choosingFavorite = true
    }
    /// Closes every sheet and the Deactivate question, so what an outside request (Control, Live Activity) shows
    /// is not hidden behind, or acted on under, something the user left open.
    func dismissPresented() {
        activating = nil
        askingFavorite = nil
        choosingFavorite = false
        deactivating = nil
        showSettings = false
        showHistory = false
        showFavorites = false
        favoritePath = []
    }
    /// Last Extend result of each role, by eligible role id (shown on the role detail, announced to VoiceOver).
    var extendResults: [String: String] = [:]
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
        extendResults[roleId] = nil
        Task {
            let text = await store.extend(eligibleRoleId: roleId)
            extendResults[roleId] = text
            VoiceOverAnnouncer.post(text)
        }
    }
}

/// Compact or regular layout. The size class decides; a window at least 600 pt wide also gets the two panes, since
/// Apple has not documented which size class the unfolded iPhone Duo reports (about 669 pt wide unfolded, 466 pt
/// folded, per the simulator's screen sizes). So any iPhone in landscape (667 pt and up) gets them too, not only a Max.
enum MobileLayout {
    static let splitMinWidth: CGFloat = 600

    static func isRegular(sizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        sizeClass == .regular || width >= splitMinWidth
    }

    /// The window's width: the geometry's width plus the side safe areas (about 59 pt each in landscape), which the
    /// geometry leaves out. Without them a 678 pt landscape window measures about 560 pt and stays compact.
    static func windowWidth(_ geometry: GeometryProxy) -> CGFloat {
        geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
    }
}
