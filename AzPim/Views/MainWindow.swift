import SwiftUI

/// Sidebar sections of the main window (AppFlow navigation rules: ⌘1–⌘3).
enum SidebarItem: String, CaseIterable, Identifiable {
    case roles = "Roles"
    case history = "History"
    case favorites = "Favorites"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roles: String(localized: "Roles")
        case .history: String(localized: "History")
        case .favorites: String(localized: "Favorites")
        }
    }

    var symbol: String {
        switch self {
        case .roles: "key.horizontal.fill"
        case .history: "clock.arrow.circlepath"
        case .favorites: "star.fill"
        }
    }

    var tint: Color {
        switch self {
        case .roles: Theme.accent
        case .history: Theme.warning
        case .favorites: Theme.violet
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .roles: "1"
        case .history: "2"
        case .favorites: "3"
        }
    }
}

/// Main window: Roles Window, History Window, Favorites Window (AppFlow).
struct MainWindow: View {
    @Environment(RoleStore.self) private var store
    @State private var selection: SidebarItem?

    /// Debug snapshots: shows a section without a sidebar highlight (an off-screen window renders it black).
    private let snapshot: SidebarItem?

    init(snapshot: SidebarItem? = nil) {
        self.snapshot = snapshot
        _selection = State(initialValue: .roles)
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: snapshot == nil ? $selection : .constant(nil)) { item in
                Label {
                    // Snapshots: a vibrant sidebar label is captured black by `cacheDisplay`; a plain colour is not.
                    Text(item.title).foregroundStyle(snapshot == nil ? Color.primary : Color(nsColor: .textColor))
                } icon: {
                    Image(systemName: item.symbol).foregroundStyle(item.tint)
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch snapshot ?? selection ?? .roles {
            case .roles: RolesView()
            case .history: HistoryView()
            case .favorites: FavoritesView()
            }
        }
        .background(shortcuts)
        .onChange(of: store.focusedRoleId, initial: true) { _, id in
            if id != nil { selection = .roles }
        }
        .onAppear { DockPolicy.mainWindowDidOpen() }
        .onDisappear { DockPolicy.mainWindowDidClose() }
    }

    /// Hidden buttons carrying the ⌘1–⌘3 shortcuts.
    private var shortcuts: some View {
        ForEach(SidebarItem.allCases) { item in
            Button("") { selection = item }
                .keyboardShortcut(item.shortcut)
                .hidden()
        }
    }
}
