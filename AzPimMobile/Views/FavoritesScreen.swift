import AzPimCore
import SwiftData
import SwiftUI

/// The favorites of this iPhone (not synced with the Mac), opened from the panel's toolbar or its favorites header:
/// reorder (Edit), delete (swipe or Edit, confirmed when the favorite holds roles), and each favorite's detail (name,
/// roles and their durations). Roles are added from a role's detail (`AddToFavoriteMenu`). Edits go through the store
/// (`RoleStore+FavoriteEditing`), as on the Mac, so the widgets follow them.
struct FavoritesScreen: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    @State private var confirmingDelete: Favorite?

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.favoritePath) {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView {
                        Label("No Favorites", systemImage: "star")
                    } description: {
                        Text("Open a role, then tap Add to favorite. A favorite activates several roles in one tap.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in FavoriteDetailScreen(favoriteId: id) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { navigation.showFavorites = false }
                }
                if !favorites.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
        }
        .confirmationDialog(confirmingDelete.map { String(localized: "Delete “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmingDelete) { favorite in
            Button("Delete", role: .destructive) { store.delete(favorite) }
        } message: { favorite in
            Text("\(favorite.items.count) roles")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(favorites) { favorite in
                    NavigationLink(value: favorite.id) { FavoriteRow(favorite: favorite) }
                        // Not a destructive-role button: that one removes the row before the question is answered.
                        .swipeActions {
                            Button { delete(favorite) } label: { Label("Delete", systemImage: "trash") }
                                .tint(Theme.danger)
                        }
                        .accessibilityAction(named: Text("Delete")) { delete(favorite) }
                }
                .onMove { store.moveFavorites(favorites, from: $0, to: $1) }
                .onDelete { offsets in
                    if let index = offsets.first { delete(favorites[index]) }
                }
            } footer: {
                Text("Tap a favorite on the panel to activate its roles. Favorites stay on this iPhone.")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A favorite without roles goes at once; one with roles is confirmed first.
    private func delete(_ favorite: Favorite) {
        if favorite.items.isEmpty {
            store.delete(favorite)
        } else {
            confirmingDelete = favorite
        }
    }
}

/// Star, name and role count.
private struct FavoriteRow: View {
    @ScaledMetric(relativeTo: .body) private var starSize: CGFloat = 30
    let favorite: Favorite

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: min(starSize, 52), height: min(starSize, 52))
                .background(Theme.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name).font(.body.weight(.medium))
                Text("\(favorite.items.count) roles").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One favorite: its name (validated as on the Mac, saved on Return or when leaving), its roles with their durations
/// (the Activation Sheet's 15-minute steps, capped by the role's policy), and Delete.
struct FavoriteDetailScreen: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    let favoriteId: UUID
    @State private var name = ""
    @State private var nameError: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let favorite = favorites.first(where: { $0.id == favoriteId }) {
            List {
                nameSection(favorite)
                rolesSection(favorite)
                Section {
                    Button("Delete favorite", role: .destructive) {
                        if favorite.items.isEmpty { delete(favorite) } else { confirmingDelete = true }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(favorite.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = favorite.name }
            .onDisappear { rename(favorite) }
            .confirmationDialog(String(localized: "Delete “\(favorite.name)”?"), isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete(favorite) }
            } message: {
                Text("\(favorite.items.count) roles")
            }
        } else {
            ContentUnavailableView("No favorite selected", systemImage: "star")
        }
    }

    private func nameSection(_ favorite: Favorite) -> some View {
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { rename(favorite) }
                .onChange(of: nameFocused) { _, focused in if !focused { rename(favorite) } }
            if let nameError {
                Text(nameError).font(.footnote).foregroundStyle(Theme.danger)
            }
        } header: {
            Text("Name")
        }
    }

    private func rolesSection(_ favorite: Favorite) -> some View {
        Section {
            ForEach(favorite.items, id: \.eligibleRoleId) { item in
                FavoriteItemRow(favorite: favorite, item: item, role: roles.first { $0.id == item.eligibleRoleId })
            }
        } header: {
            Text("Roles")
        } footer: {
            if favorite.items.isEmpty {
                Text("Add at least one role.")
            } else {
                Text("Add roles from a role's detail. Each duration is capped by the role's policy when the favorite runs.")
            }
        }
    }

    private func rename(_ favorite: Favorite) {
        switch store.rename(favorite, to: name, others: favorites.filter { $0.id != favorite.id }.map(\.name)) {
        case .success:
            nameError = nil
        case .failure(let failure):
            nameError = String(localized: "\(failure.userMessage) — kept “\(favorite.name)”.")
            VoiceOverAnnouncer.post(nameError)
        }
    }

    private func delete(_ favorite: Favorite) {
        navigation.favoritePath.removeAll { $0 == favorite.id }
        store.delete(favorite)
    }
}

/// A role of the favorite: source square, name and scope (or « No longer eligible »), its duration, and Remove.
private struct FavoriteItemRow: View {
    @Environment(RoleStore.self) private var store
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 30
    let favorite: Favorite
    let item: FavoriteItem
    let role: EligibleRole?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let role {
                    SourceBadge(source: role.source, size: min(badgeSize, 52))
                    RoleTitle(name: role.displayRoleName, scope: role.displayScopeName)
                } else {
                    RoleTitle(name: String(localized: "No longer eligible"), scope: item.eligibleRoleId)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            DurationPicker(minutes: Binding(get: { RoleStore.favoriteDurationMinutes(favorite, roleId: item.eligibleRoleId,
                                                                                         policyMax: role?.maxDuration) },
                                            set: { store.setDuration(minutes: $0, roleId: item.eligibleRoleId, in: favorite) }),
                           policyMax: role?.maxDuration)
            if role?.requiresTicket == true {
                Text("Asks for the ticket when the favorite runs.").font(.footnote).foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { remove() } label: { Label("Remove from favorite", systemImage: "minus.circle") }
        }
        .accessibilityAction(named: Text("Remove from favorite")) { remove() }
    }

    private func remove() {
        store.removeItem(item.eligibleRoleId, from: favorite)
        VoiceOverAnnouncer.post(String(localized: "Removed from favorite"))
    }
}
