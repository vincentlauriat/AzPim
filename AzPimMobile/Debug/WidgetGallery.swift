#if DEBUG
import SwiftUI
import WidgetKit

/// Debug only, `AZPIM_DEMO=widgets`: the widgets drawn by the app from the snapshot file it just wrote to the App Group
/// (the extension's read path), at their home-screen and lock-screen sizes, now and after the first role ends (the
/// timeline's next entries). For screenshots: the simulator cannot add widgets from the command line.
struct WidgetGallery: View {
    @State private var snapshot: WidgetSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let snapshot {
                    let now = Date.now
                    let later = snapshot.roles.compactMap(\.endAt).filter { $0 > now }.min()?.addingTimeInterval(1)
                    caption("Active roles · now")
                    HStack(spacing: 14) {
                        tile(.systemSmall) { ActiveRolesWidgetView(roles: snapshot.liveRoles(at: now), date: now, family: .systemSmall) }
                        lockScreen(snapshot.liveRoles(at: now), date: now)
                    }
                    tile(.systemMedium) { ActiveRolesWidgetView(roles: snapshot.liveRoles(at: now), date: now, family: .systemMedium) }
                    if let later {
                        caption("After the first end (\(snapshot.entryDates(now: now).count) timeline entries)")
                        tile(.systemMedium) {
                            ActiveRolesWidgetView(roles: snapshot.liveRoles(at: later), date: later, family: .systemMedium)
                        }
                    }
                    caption("Favorites · empty state")
                    HStack(spacing: 14) {
                        tile(.systemSmall) { FavoritesWidgetView(favorites: snapshot.favorites, family: .systemSmall) }
                        tile(.systemSmall) { ActiveRolesWidgetView(roles: [], date: now, family: .systemSmall) }
                    }
                    tile(.systemMedium) { FavoritesWidgetView(favorites: snapshot.favorites, family: .systemMedium) }
                } else {
                    Text(verbatim: "No snapshot in the App Group (unsigned build?)")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.1, green: 0.42, blue: 0.48)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        }
        .environment(\.widgetStaticDial, true)
        .task {
            // The writer runs when the app becomes active: read the file once it is there (and not an older one).
            let launched = Date.now.addingTimeInterval(-5)
            for _ in 0..<20 {
                if let read = WidgetSnapshot.read(), read.generatedAt > launched { snapshot = read; return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            snapshot = WidgetSnapshot.read()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.caption.weight(.semibold)).foregroundStyle(.white)
    }

    private func tile(_ family: WidgetFamily, @ViewBuilder content: () -> some View) -> some View {
        let size = family == .systemSmall ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158)
        return content()
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Lock screen accessories: white on the wallpaper, as the system renders them (vibrant).
    private func lockScreen(_ roles: [WidgetSnapshot.Role], date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ActiveRolesWidgetView(roles: roles, date: date, family: .accessoryInline).font(.subheadline).lineLimit(1)
            ActiveRolesWidgetView(roles: roles, date: date, family: .accessoryRectangular).frame(width: 160, height: 72)
            ActiveRolesWidgetView(roles: roles, date: date, family: .accessoryCircular).frame(width: 72, height: 72)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(width: 166, alignment: .leading)
    }
}
#endif
