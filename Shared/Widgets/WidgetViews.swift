import SwiftUI
import WidgetKit

// The widgets' views (2.0 step 4b), compiled by the widget extension, which draws them from the snapshot, and by the
// app, whose Debug widget gallery renders them for screenshots. The family is a parameter (not `\.widgetFamily`), so
// the gallery can draw every size. Countdowns are `Text(timerInterval:)` and the ring `ProgressView(timerInterval:)`:
// they move by themselves between timeline entries.

// MARK: - Active roles

struct ActiveRolesWidgetView: View {
    let roles: [WidgetSnapshot.Role]
    let date: Date
    let family: WidgetFamily

    var body: some View {
        if let first = roles.first {
            let others = roles.count - 1
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    RoleRing(role: first, date: date, lineWidth: 5)
                        .padding(4)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(first.name))
            case .accessoryInline:
                // « ☁︎ Contributor 1:23:45 »: one line, the symbol, the name and the countdown.
                let label = Text(Image(systemName: first.symbol)) + Text(verbatim: " \(first.name) ")
                if let end = first.endAt {
                    label + RoleCountdown.text(end, date: date)
                } else {
                    label + Text("Permanent")
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label(first.name, systemImage: first.symbol).font(.headline).lineLimit(1).widgetAccentable()
                    RoleCountdown(role: first, date: date).font(.body.weight(.semibold).monospacedDigit())
                    if others > 0 {
                        Text("+\(others) other active roles").font(.caption).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                RoleList(roles: roles, date: date)
            default:
                SoonestRole(role: first, others: others, date: date)
            }
        } else {
            EmptyRoles(family: family)
        }
    }
}

/// Small widget: the role that ends first, its dial and countdown, « +N » other roles.
private struct SoonestRole: View {
    let role: WidgetSnapshot.Role
    let others: Int
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                RoleRing(role: role, date: date, lineWidth: 5).frame(width: 44, height: 44)
                Spacer(minLength: 4)
                if others > 0 {
                    Text("+\(others)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.slate)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.track, in: Capsule())
                        .accessibilityLabel(Text("+\(others) other active roles"))
                }
            }
            Spacer(minLength: 0)
            Text(role.name).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            Text(role.scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            RoleCountdown(role: role, date: date)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(RoleTone.color(role, at: date))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Medium widget: up to three roles, the ones ending first on top, then « +N more ».
private struct RoleList: View {
    let roles: [WidgetSnapshot.Role]
    let date: Date
    static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Active roles").font(.caption.weight(.semibold)).foregroundStyle(Theme.slate)
                Spacer()
                if roles.count > Self.shown {
                    Text("+\(roles.count - Self.shown) other active roles").font(.caption).foregroundStyle(Theme.slate)
                }
            }
            ForEach(roles.prefix(Self.shown)) { role in
                HStack(spacing: 10) {
                    RoleRing(role: role, date: date, lineWidth: 3).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(role.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(role.scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    RoleCountdown(role: role, date: date)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(RoleTone.color(role, at: date))
                        .lineLimit(1)
                        .frame(maxWidth: 84, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EmptyRoles: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "checkmark.shield").font(.title3)
            }
            .accessibilityLabel(Text("No active role"))
        case .accessoryInline:
            Label("No active role", systemImage: "checkmark.shield")
        case .accessoryRectangular:
            Label("No active role", systemImage: "checkmark.shield").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.shield").font(.title2).foregroundStyle(Theme.slate)
                Spacer(minLength: 0)
                Text("No active role").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// The time left, ticking by itself (« Permanent » for an assignment without an end). The range is clamped: an end
/// in the past would make an invalid range.
struct RoleCountdown: View {
    let role: WidgetSnapshot.Role
    let date: Date

    var body: some View {
        if let end = role.endAt {
            Self.text(end, date: date)
        } else {
            Text("Permanent")
        }
    }

    static func text(_ end: Date, date: Date) -> Text {
        end <= date ? Text("Expired") : Text(timerInterval: date...end, countsDown: true)
    }
}

/// The countdown dial (the app icon's): the share of the activation left, in the countdown's tone, the source's symbol
/// inside. A full slate ring for a permanent assignment.
struct RoleRing: View {
    let role: WidgetSnapshot.Role
    let date: Date
    let lineWidth: CGFloat
    /// The gallery draws the dial at its entry date: outside a widget a timer `ProgressView` shows a spinner.
    @Environment(\.widgetStaticDial) private var staticDial

    var body: some View {
        let tone = RoleTone.color(role, at: date)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            if let start = role.startAt, let end = role.endAt, end > date, !staticDial {
                ProgressView(timerInterval: min(start, date)...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(tone)
            } else {
                Circle()
                    .trim(from: 0, to: RoleTone.fraction(role, at: date))
                    .stroke(tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: role.symbol)
                .font(.system(size: lineWidth * 3, weight: .semibold))
                .foregroundStyle(tone)
                .widgetAccentable()
        }
        .accessibilityHidden(true)
    }
}

enum RoleTone {
    /// Green with time left, orange in the last 15 minutes, red in the last 5 (`Theme.remaining`); slate when permanent.
    /// Fixed for a timeline entry: the timeline has an entry at each threshold.
    static func color(_ role: WidgetSnapshot.Role, at date: Date) -> Color {
        guard let end = role.endAt else { return Theme.slate }
        return Theme.remaining(end.timeIntervalSince(date))
    }

    /// Share of the activation left at `date` (1 for a permanent assignment).
    static func fraction(_ role: WidgetSnapshot.Role, at date: Date) -> Double {
        guard let start = role.startAt, let end = role.endAt, end > start else { return 1 }
        return min(1, max(0, end.timeIntervalSince(date) / end.timeIntervalSince(start)))
    }
}

extension EnvironmentValues {
    @Entry var widgetStaticDial = false
}

// MARK: - Favorites

/// Favorites: a tap opens the favorite's confirmation in the app (`azpim://favorite?id=`), never activates directly.
/// Small: one tap target only (WidgetKit ignores `Link` there), so it shows the first favorite and its link.
/// Medium: up to four favorites, each its own link.
struct FavoritesWidgetView: View {
    let favorites: [WidgetSnapshot.Favorite]
    let family: WidgetFamily
    static let shownInMedium = 4

    var body: some View {
        if favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "star").font(.title2).foregroundStyle(Theme.violet)
                Spacer(minLength: 0)
                Text("No favorites").font(.headline)
                Text("Create favorites in AzPim.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if family == .systemMedium {
            VStack(alignment: .leading, spacing: 6) {
                Text("Favorites").font(.caption.weight(.semibold)).foregroundStyle(Theme.slate)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(favorites.prefix(Self.shownInMedium)) { favorite in
                        Link(destination: WidgetSnapshot.favoriteURL(favorite.id) ?? Self.appURL) {
                            FavoriteTile(favorite: favorite)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let first = favorites.first {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "star.fill").font(.title2).foregroundStyle(Theme.violet)
                Spacer(minLength: 0)
                Text(first.name).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                Text("\(first.roleCount) roles").font(.caption).foregroundStyle(.secondary)
                if favorites.count > 1 {
                    Text("+\(favorites.count - 1) favorites").font(.caption).foregroundStyle(Theme.slate)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(WidgetSnapshot.favoriteURL(first.id))
        }
    }

    /// Opens the app (an unknown `azpim://` host does nothing more).
    static let appURL = URL(string: "azpim://open") ?? URL(fileURLWithPath: "/")
}

private struct FavoriteTile: View {
    let favorite: WidgetSnapshot.Favorite

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill").foregroundStyle(Theme.violet).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(favorite.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2).minimumScaleFactor(0.85)
                Text("\(favorite.roleCount) roles").font(.caption2).foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
