import AzPimCore
import SwiftData
import SwiftUI

/// Menu items adding a role to an existing favorite or to a new one.
struct AddToFavoriteMenu: View {
    @Environment(\.modelContext) private var context
    @Environment(RoleStore.self) private var store
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    let role: EligibleRole

    /// The last duration used for the role, else 1 h (least privilege), not the policy maximum.
    private var item: FavoriteItem { FavoriteItem(eligibleRoleId: role.id, duration: store.defaultFavoriteDuration(for: role)) }

    var body: some View {
        ForEach(favorites) { favorite in
            Button(favorite.name) {
                guard !favorite.items.contains(where: { $0.eligibleRoleId == role.id }) else { return }
                favorite.items.append(item)
                try? context.save()
            }
            .disabled(favorite.items.contains { $0.eligibleRoleId == role.id })
        }
        if !favorites.isEmpty { Divider() }
        Button("New favorite with this role") {
            let names = favorites.map(\.name)
            let base = String(role.roleName.prefix(34))   // room for " 99" under the 40-char limit
            var name = base
            var index = 2
            while case .failure = Validation.favoriteName(name, existing: names), index < 1000 {
                name = "\(base) \(index)"
                index += 1
            }
            context.insert(Favorite(name: name, items: [item],
                                    sortOrder: (favorites.map(\.sortOrder).max() ?? -1) + 1))
            try? context.save()
        }
    }
}
