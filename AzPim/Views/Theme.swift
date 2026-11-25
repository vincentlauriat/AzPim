#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Design tokens shared by the menu bar panel and the windows (DesignBrief, Juicy / Claude Cockpit look):
/// rounded cards, a large hero figure, collapsible sections, a settings-style action list.
enum Theme {
    // MARK: Layout
    static let panelWidth: CGFloat = 360
    static let cardRadius: CGFloat = 14

    // MARK: Colours

    /// Text tokens (also icons and tinted capsules): 4.5:1 or more on a card and inside their own 14 % tint, in light
    /// and dark, normal and Increase Contrast (AzPimTests › ThemeContrastTests).
    /// Azure blue — primary emphasis.
    static let accent = Tone.accent.color
    /// Active role (the hero figure, countdowns with time left).
    static let active = Tone.active.color
    static let warning = Tone.warning.color
    static let danger = Tone.danger.color
    /// Favorites, PIM groups.
    static let violet = Tone.violet.color
    static let slate = Tone.slate.color
    /// Entra roles (iPhone source icons).
    static let teal = Tone.teal.color

    /// Fill of a prominent button (Activate): its white label keeps 4.5:1 or more.
    static let accentFill = Tone.accentFill.color

    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.12)

    /// A colour token: light and dark, and their Increase Contrast versions (darker in light mode, lighter in dark
    /// mode).
    struct Tone {
        let light: UInt32, dark: UInt32, lightContrast: UInt32, darkContrast: UInt32

        static let accent = Tone(light: 0x0D5A9E, dark: 0x63B0F3, lightContrast: 0x0A4F8F, darkContrast: 0x8CC8FF)
        static let active = Tone(light: 0x0B6633, dark: 0x34C66B, lightContrast: 0x075C2C, darkContrast: 0x5EE08C)
        static let warning = Tone(light: 0x8A4908, dark: 0xF5A524, lightContrast: 0x7A3D00, darkContrast: 0xFFC266)
        static let danger = Tone(light: 0xA62529, dark: 0xF78E93, lightContrast: 0x9A1A1E, darkContrast: 0xFF9EA1)
        static let violet = Tone(light: 0x5026F2, dark: 0xB19EFF, lightContrast: 0x4A2AC9, darkContrast: 0xC2B5FF)
        static let slate = Tone(light: 0x525A65, dark: 0xA3ABB6, lightContrast: 0x3A414A, darkContrast: 0xC4CBD3)
        static let teal = Tone(light: 0x085E68, dark: 0x3CC4CF, lightContrast: 0x075A63, darkContrast: 0x6FDDE6)
        static let accentFill = Tone(light: 0x0F6CBD, dark: 0x0F6CBD, lightContrast: 0x0A4F8F, darkContrast: 0x0A4F8F)
        static let text: [(name: String, tone: Tone)] = [("accent", accent), ("active", active), ("warning", warning),
                                                         ("danger", danger), ("violet", violet), ("slate", slate),
                                                         ("teal", teal)]

        func hex(dark isDark: Bool, increasedContrast: Bool) -> UInt32 {
            switch (isDark, increasedContrast) {
            case (false, false): light
            case (true, false): dark
            case (false, true): lightContrast
            case (true, true): darkContrast
            }
        }

        /// Resolved when drawn, from the appearance: with Increase Contrast on, the system's best match is one of the
        /// high-contrast appearances.
        var color: Color {
            let tone = self
            #if os(iOS)
            return Color(uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                var increased = traits.accessibilityContrast == .high
                #if DEBUG
                increased = Theme.contrastOverride ?? increased
                #endif
                return UIColor(hex: tone.hex(dark: isDark, increasedContrast: increased))
            })
            #else
            return Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                        .accessibilityHighContrastDarkAqua])
                let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                var increased = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                #if DEBUG
                increased = Theme.contrastOverride ?? increased
                #endif
                return NSColor(hex: tone.hex(dark: isDark, increasedContrast: increased))
            })
            #endif
        }
    }

    #if DEBUG
    /// Snapshots and tests of the Increase Contrast look: a high-contrast `NSAppearance` cannot be created by name
    /// (`NSAppearance(named:)` returns plain Aqua), so the renders force the tokens instead. Main thread only.
    nonisolated(unsafe) static var contrastOverride: Bool?
    #endif

    /// Countdown tint: green with time left, orange ≤ 15 min, red ≤ 5 min.
    static func remaining(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return active }
        if seconds <= 300 { return danger }
        if seconds <= 900 { return warning }
        return active
    }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Containers

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Uppercase tracked label (« TEMPS RESTANT »).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.slate)
    }
}

/// KPI tile: label, big value, optional note.
struct StatTile: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = .primary
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                SectionLabel(text: label)
            }
            Text(value)
                .font(.display(26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.slate).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

/// Collapsible card with an icon, a title, an optional count and a chevron.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var count: Int?
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.track, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isHeader)
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .card()
    }

    /// « Eligible roles, 4, expanded ».
    private var accessibilityText: String {
        let name = count.map { "\(title), \($0)" } ?? title
        return expanded ? String(localized: "\(name), expanded") : String(localized: "\(name), collapsed")
    }
}

/// Settings-list row with a leading SF Symbol (footer of the panel).
struct ActionRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Thin divider between rows of a card, inset past the leading icon.
struct RowDivider: View {
    var inset: CGFloat = 34
    var body: some View { Divider().opacity(0.5).padding(.leading, inset) }
}

/// Progress track with a rounded fill (hero card).
struct ProgressTrack: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: max(8, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
