import SwiftUI
import WidgetKit

/// Home-screen and lock-screen widgets (2.0 step 4b), drawn from the snapshot the app writes to the App Group container
/// (`WidgetSnapshot`). The extension only reads that file: no store, no token, no network, no write.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil before the app first wrote a snapshot.
    let snapshot: WidgetSnapshot?

    var roles: [WidgetSnapshot.Role] { snapshot?.liveRoles(at: date) ?? [] }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetSnapshot.read()
        // The widget gallery shows a sample while AzPim has nothing to show yet.
        let sample = context.isPreview && (snapshot?.roles.isEmpty ?? true)
        completion(SnapshotEntry(date: .now, snapshot: sample ? .placeholder : snapshot))
    }

    /// An entry now, then at each colour threshold and each end: an expired role leaves the widget without the app.
    /// The app reloads the timelines when the snapshot changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        guard let snapshot = WidgetSnapshot.read() else {
            completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: nil)], policy: .never))
            return
        }
        let dates = snapshot.entryDates(now: now)
        let entries = dates.map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: snapshot.reloadDate(after: dates).map { .after($0) } ?? .never))
    }
}

struct ActiveRolesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.vincentlauriat.azpim.activeRoles", provider: SnapshotProvider()) { entry in
            FamilyView { family in
                ActiveRolesWidgetView(roles: entry.roles, date: entry.date, family: family)
            }
            .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Active roles")
        .description("Your active roles and the time left on each.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.vincentlauriat.azpim.favorites", provider: SnapshotProvider()) { entry in
            FamilyView { family in
                FavoritesWidgetView(favorites: entry.snapshot?.favorites ?? [], family: family)
            }
            .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Favorites")
        .description("Open a favorite's confirmation in AzPim.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Hands the widget's family to the shared views (the app's gallery passes it by hand).
private struct FamilyView<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content

    var body: some View { content(family) }
}

extension WidgetSnapshot {
    /// The widget gallery's sample, and the placeholder while the widget loads (redacted by the system).
    static var placeholder: WidgetSnapshot {
        let now = Date.now
        return WidgetSnapshot(generatedAt: now, roles: [
            Role(id: "1", name: "Contributor", scope: "Production", symbol: "cloud",
                 startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(2 * 3600 + 840)),
            Role(id: "2", name: "Global Reader", scope: "Directory", symbol: "person.badge.key",
                 startAt: now.addingTimeInterval(-600), endAt: now.addingTimeInterval(4 * 3600))
        ], favorites: [Favorite(id: UUID(), name: "Morning", roleCount: 3)])
    }
}
