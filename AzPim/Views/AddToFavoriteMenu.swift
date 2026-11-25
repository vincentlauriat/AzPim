import AzPimCore
import SwiftData
import SwiftUI

/// Menu items adding a role to an existing favorite or to a new one (Mac Roles Window, iPhone role detail and rows).
struct AddToFavoriteMenu: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    let role: EligibleRole
    /// Called with the favorite the role went into (the iPhone's confirmation and haptic).
    var onAdded: ((Favorite) -> Void)?

    var body: some View {
        ForEach(favorites) { favorite in
            Button(favorite.name) {
                if store.add(role, to: favorite) { onAdded?(favorite) }
            }
            .disabled(favorite.items.contains { $0.eligibleRoleId == role.id })
        }
        if !favorites.isEmpty { Divider() }
        Button("New favorite with this role") {
            let favorite = store.newFavorite(with: role, among: favorites)
            onAdded?(favorite)
        }
    }
}
