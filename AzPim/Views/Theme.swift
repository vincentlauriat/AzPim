import AppKit
import SwiftUI

/// Design tokens shared by the menu bar panel and the windows (DesignBrief, Juicy / Claude Cockpit look):
/// rounded cards, a large hero figure, collapsible sections, a settings-style action list.
enum Theme {
    // MARK: Layout
    static let panelWidth: CGFloat = 360
    static let cardRadius: CGFloat = 14

    // MARK: Colours

    /// Azure blue — primary emphasis.
    static let accent = Tone.accent.color
    /// Active role (the hero figure, countdowns with time left).
    static let active = Tone.active.color
    static let warning = Tone.warning.color
    static let danger = Tone.danger.color
    /// Favorites, PIM groups.
    static let violet = Tone.violet.color

    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.12)
    static let slate = Tone.slate.color

    /// A colour token: light and dark, and their Increase Contrast versions (darker in light mode, lighter in dark
    /// mode), which keep coloured text at 4.5:1 or more on a card and on its own 14 % tinted capsule
    /// (AzPimTests › ThemeContrastTests).
    struct Tone {
        let light: UInt32, dark: UInt32, lightContrast: UInt32, darkContrast: UInt32

        static let accent = Tone(light: 0x0F6CBD, dark: 0x4CA3F0, lightContrast: 0x0A4F8F, darkContrast: 0x8CC8FF)
        static let active = Tone(light: 0x12A150, dark: 0x34C66B, lightContrast: 0x075C2C, darkContrast: 0x5EE08C)
        static let warning = Tone(light: 0xD9730D, dark: 0xF5A524, lightContrast: 0x7A3D00, darkContrast: 0xFFC266)
        static let danger = Tone(light: 0xD13438, dark: 0xF1545A, lightContrast: 0xA1191D, darkContrast: 0xFF9EA1)
        static let violet = Tone(light: 0x7A5AF8, dark: 0x9B84FF, lightContrast: 0x5435D6, darkContrast: 0xC2B5FF)
        static let slate = Tone(light: 0x5B6470, dark: 0x9AA3AE, lightContrast: 0x3A414A, darkContrast: 0xC4CBD3)
        static let all: [(name: String, tone: Tone)] = [("accent", accent), ("active", active), ("warning", warning),
                                                        ("danger", danger), ("violet", violet), ("slate", slate)]

        func hex(dark isDark: Bool, increasedContrast: Bool) -> UInt32 {
            switch (isDark, increasedContrast) {
            case (false, false): light
            case (true, false): dark
            case (false, true): lightContrast
            case (true, true): darkContrast
            }
        }

        /// Resolved when drawn: follows the appearance and the Increase Contrast setting.
        var color: Color {
            let tone = self
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: tone.hex(dark: isDark, increasedContrast: Theme.increasedContrast))
            })
        }
    }

    #if DEBUG
    /// Snapshots of the Increase Contrast look (the system setting cannot be faked per window).
    nonisolated(unsafe) static var contrastOverride: Bool?
    #endif

    /// System Settings › Accessibility › Display › Increase contrast.
    static var increasedContrast: Bool {
        #if DEBUG
        if let contrastOverride { return contrastOverride }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Countdown tint: green with time left, orange ≤ 15 min, red ≤ 5 min.
    static func remaining(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return active }
        if seconds <= 300 { return danger }
        if seconds <= 900 { return warning }
        return active
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}

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
