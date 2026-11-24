import AzPimCore
import SwiftUI

/// Opened by the Control Center control « Run Favorite » (`OpenFavoritesIntent`, iOS 18): the favorites, then the
/// chosen one's grouped sheet (`FavoriteActivationSheet`), which is the confirmation. A tap here never activates: even
/// a favorite that needs no justification or ticket is shown first (`RoleStore.favoriteRunRequest`, not
/// `startFavorite`). With a single favorite, its sheet opens at once.
struct FavoriteChooserSheet: View {
    @Environment(RoleStore.self) private var store
    let close: () -> Void

    /// Nil until read (no « No Favorites » flash).
    @State private var favorites: [Favorite]?
    @State private var request: FavoriteRunRequest?
    @State private var loading: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let request {
                    ScrollView { FavoriteActivationSheet(request: request, fromPanel: false, close: close).padding(.top, 8) }
                } else if let favorites, favorites.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "star",
                                           description: Text("This iPhone has no favorite with roles yet."))
                } else if let favorites {
                    list(favorites)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Run Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if request == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                }
            }
        }
        .task {
            let runnable = store.runnableFavorites()
            favorites = runnable
            if runnable.count == 1, let only = runnable.first { await choose(only) }
        }
    }

    private func list(_ favorites: [Favorite]) -> some View {
        List(favorites) { favorite in
            Button {
                Task { await choose(favorite) }
            } label: {
                HStack {
                    Label(favorite.name, systemImage: "star.fill").foregroundStyle(Theme.violet)
                    Spacer()
                    if loading == favorite.id {
                        ProgressView()
                    } else {
                        Text("\(favorite.items.count) roles").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(loading != nil)
        }
    }

    /// Reads the roles the favorite would send (policies fetched if never read), then shows its sheet.
    private func choose(_ favorite: Favorite) async {
        loading = favorite.id
        defer { loading = nil }
        request = await store.favoriteRunRequest(favorite)
    }
}
