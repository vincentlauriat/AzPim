import Foundation

/// What the iPhone home-screen and lock-screen widgets show (2.0 step 4b): the active roles as the panel shows them and
/// the favorites. The app writes it to the App Group container after every refresh and when it comes to the foreground
/// or leaves it (`WidgetSnapshotWriter`); the widget extension only reads it (no store, no token, no network).
/// Foundation only: compiled by both apps and the extension, tested on Mac. Holds display names only: no token, no
/// account, no tenant, no id beyond the favorites' (the links that open their confirmation).
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Role: Codable, Equatable, Sendable, Identifiable {
        /// The row's position in the list (only tells the rows apart; no account or Azure id leaves the app).
        let id: String
        /// Role and scope names as the app shows them (translated when AzPim translates them).
        let name: String
        let scope: String
        /// SF Symbol of the role's source (`SourceIcon`).
        let symbol: String
        /// Activation start (the countdown ring), nil for a permanent assignment.
        let startAt: Date?
        /// Activation end, nil for a permanent assignment.
        let endAt: Date?

        var isPermanent: Bool { endAt == nil }

        /// Still active at `date`: a permanent assignment always is.
        func isLive(at date: Date) -> Bool { endAt.map { $0 > date } ?? true }
    }

    struct Favorite: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let name: String
        let roleCount: Int
    }

    let generatedAt: Date
    /// Activations, the one ending first on top, then permanent assignments by name.
    let roles: [Role]
    /// In the app's order.
    let favorites: [Favorite]

    static let empty = WidgetSnapshot(generatedAt: .distantPast, roles: [], favorites: [])

    /// Same roles and favorites, whatever `generatedAt`: the widgets only reload when this changes.
    func hasSameContent(as other: WidgetSnapshot?) -> Bool {
        roles == other?.roles && favorites == other?.favorites
    }

    func liveRoles(at date: Date) -> [Role] { roles.filter { $0.isLive(at: date) } }

    // MARK: - Timeline

    /// Countdown colour thresholds (`Theme.remaining`): orange from 15 minutes left, red from 5.
    static let toneThresholds: [TimeInterval] = [900, 300]
    /// A widget timeline is a budget: dates past this many are left to the next reload.
    static let maxEntries = 40

    /// When the widgets must be drawn again without the app: now, then each end of an activation (it disappears) and
    /// each colour threshold before it, in order, without duplicates. Each entry shows the roles still live at its date.
    func entryDates(now: Date) -> [Date] {
        let ends = roles.compactMap(\.endAt).filter { $0 > now }
        let marks = ends.flatMap { end in [end] + Self.toneThresholds.map { end.addingTimeInterval(-$0) } }
        let future = Set(marks.filter { $0 > now }).sorted()
        return Array(([now] + future).prefix(Self.maxEntries))
    }

    /// When to ask for a new timeline: past the last entry while an activation is still live (more entries than the
    /// budget), else never (the app reloads the widgets when the snapshot changes).
    func reloadDate(after dates: [Date]) -> Date? {
        guard let last = dates.last, roles.contains(where: { $0.endAt.map { $0 > last } ?? false }) else { return nil }
        return last
    }

    // MARK: - File

    static let appGroup = "group.fr.vincentlauriat.azpim"
    static let fileName = "widget-snapshot.json"

    /// The snapshot file in the App Group container; nil when the App Group is not available (unsigned build).
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// The last snapshot the app wrote, nil when there is none (app never opened, or no App Group).
    static func read(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    // MARK: - Links

    /// `azpim://favorite?id=<uuid>`: opens the favorite's confirmation in the iPhone app (never runs it directly).
    static func favoriteURL(_ id: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = "azpim"
        components.host = "favorite"
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return components.url
    }

    /// The favorite id of an `azpim://favorite?id=<uuid>` link, else nil.
    static func favoriteID(in url: URL) -> UUID? {
        guard url.scheme == "azpim", url.host() == "favorite",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value else { return nil }
        return UUID(uuidString: value)
    }
}
