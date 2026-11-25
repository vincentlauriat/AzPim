import AzPimCore
import Foundation
import SwiftData

/// Favorite edits shared by the Mac (Favorites Window, Add to favorite menus) and the iPhone (Favorites screen, role
/// detail): each one saves, then posts `favoritesDidChange` so the iPhone's widget snapshot follows.
extension RoleStore {
    /// Posted (object: the store) after every favorite edit is saved.
    nonisolated static let favoritesDidChange = Notification.Name("fr.vincentlauriat.azpim.favoritesDidChange")

    /// `base`, else `base 2`, `base 3`… : the first name `Validation.favoriteName` accepts among `existing`.
    /// `maxIndex` bounds the search (a role name cut to leave room for the suffix); nil: unbounded.
    nonisolated static func uniqueFavoriteName(_ base: String, existing: [String], maxIndex: Int? = nil) -> String {
        var name = base
        var index = 2
        while case .failure = Validation.favoriteName(name, existing: existing), maxIndex.map({ index < $0 }) ?? true {
            name = "\(base) \(index)"
            index += 1
        }
        return name
    }

    /// Sort order after the last favorite.
    nonisolated static func nextFavoriteSortOrder(_ favorites: [Favorite]) -> Int {
        (favorites.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Adds the role with its default duration (the last one used, else 1 h: least privilege, not the policy maximum).
    /// False when the favorite already holds it.
    @discardableResult
    func add(_ role: EligibleRole, to favorite: Favorite) -> Bool {
        guard !favorite.items.contains(where: { $0.eligibleRoleId == role.id }) else { return false }
        favorite.items.append(FavoriteItem(eligibleRoleId: role.id, duration: defaultFavoriteDuration(for: role)))
        saveFavorites()
        return true
    }

    /// A new favorite holding only this role, named after it (cut to leave room for " 99" under the 40-char limit).
    @discardableResult
    func newFavorite(with role: EligibleRole, among favorites: [Favorite]) -> Favorite {
        let name = Self.uniqueFavoriteName(String(role.roleName.prefix(34)), existing: favorites.map(\.name), maxIndex: 1000)
        let favorite = Favorite(name: name,
                                items: [FavoriteItem(eligibleRoleId: role.id, duration: defaultFavoriteDuration(for: role))],
                                sortOrder: Self.nextFavoriteSortOrder(favorites))
        context.insert(favorite)
        saveFavorites()
        return favorite
    }

    /// A new favorite without roles, « New favorite » (Favorites Window › +).
    func newEmptyFavorite(among favorites: [Favorite]) -> Favorite {
        let name = Self.uniqueFavoriteName(String(localized: "New favorite"), existing: favorites.map(\.name))
        let favorite = Favorite(name: name, items: [], sortOrder: Self.nextFavoriteSortOrder(favorites))
        context.insert(favorite)
        saveFavorites()
        return favorite
    }

    /// Reorders `favorites` (in their current order) and renumbers them from 0.
    func moveFavorites(_ favorites: [Favorite], from source: IndexSet, to destination: Int) {
        var list = favorites
        list.move(fromOffsets: source, toOffset: destination)
        for (index, favorite) in list.enumerated() { favorite.sortOrder = index }
        saveFavorites()
    }

    func delete(_ favorite: Favorite) {
        context.delete(favorite)
        saveFavorites()
    }

    /// Renames after `Validation.favoriteName` against the other favorites' names. Nothing is saved when it fails or
    /// when the name is unchanged; a deleted favorite (an editor closing after its deletion) is left alone.
    @discardableResult
    func rename(_ favorite: Favorite, to raw: String, others: [String]) -> Result<String, Validation.Failure> {
        guard favorite.modelContext != nil, !favorite.isDeleted else { return .success(raw) }
        let result = Validation.favoriteName(raw, existing: others)
        if case .success(let valid) = result, valid != favorite.name {
            favorite.name = valid
            saveFavorites()
        }
        return result
    }

    func removeItem(_ eligibleRoleId: String, from favorite: Favorite) {
        favorite.items.removeAll { $0.eligibleRoleId == eligibleRoleId }
        saveFavorites()
    }

    /// The item's saved duration in minutes, shown capped by the role's current policy (the run caps it too).
    nonisolated static func favoriteDurationMinutes(_ favorite: Favorite, roleId: String, policyMax: String?) -> Int {
        let saved = favorite.items.first { $0.eligibleRoleId == roleId }?.duration
        let minutes = saved.flatMap(ISODuration.seconds).map { Int(($0 / 60).rounded()) }
        return ActivationDuration.clamp(minutes ?? ActivationDuration.fallbackMinutes, policyMax: policyMax)
    }

    /// Resolves the item by role id at each call: an index could point to a neighbour after a removal.
    func setDuration(minutes: Int, roleId: String, in favorite: Favorite) {
        guard let index = favorite.items.firstIndex(where: { $0.eligibleRoleId == roleId }) else { return }
        favorite.items[index].duration = ActivationDuration.iso(minutes)
        saveFavorites()
    }

    func setJustification(_ text: String, roleId: String, in favorite: Favorite) {
        guard let index = favorite.items.firstIndex(where: { $0.eligibleRoleId == roleId }) else { return }
        favorite.items[index].justification = text.isEmpty ? nil : String(text.prefix(500))
        saveFavorites()
    }

    private func saveFavorites() {
        try? context.save()
        NotificationCenter.default.post(name: Self.favoritesDidChange, object: self)
    }
}
