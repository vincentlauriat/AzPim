import AzPimCore
import Foundation
import SwiftData

extension MobileNavigation {
    /// `azpim://favorite?id=<uuid>` (a Favorites widget tap): opens the favorite's grouped sheet, which lists its roles
    /// and waits for Activate. Never runs the favorite directly, even when nothing needs to be asked: any app can open
    /// the link. Ignored while another sheet is open; a favorite with no role left to send (all active or waiting) only
    /// brings the app forward, where the panel shows them.
    func openFavorite(_ url: URL, store: RoleStore) {
        guard let id = WidgetSnapshot.favoriteID(in: url) else { return }
        Task {
            // After a cold launch by the link: the launch refresh first, so superseded accounts are left out.
            guard (try? await store.intentReady()) != nil, !isPresentingSheet,
                  let favorite = ((try? store.context.fetch(FetchDescriptor<Favorite>())) ?? []).first(where: { $0.id == id })
            else { return }
            // Background token mode, as for a Shortcuts link: no sign-in window opens before the confirmation (a policy
            // that can't be read shows as not sent in the sheet).
            let roles = await TokenInteraction.$isBackground.withValue(true) { await store.favoriteRolesToSend(favorite) }
            guard !roles.isEmpty, !isPresentingSheet else { return }
            askingFavorite = FavoriteRunRequest(favorite: favorite, roles: roles)
        }
    }

    private var isPresentingSheet: Bool {
        activating != nil || askingFavorite != nil || choosingFavorite || deactivating != nil || showSettings || showHistory
    }
}
