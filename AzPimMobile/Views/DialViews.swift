import AzPimCore
import SwiftUI

/// The iPhone's visual language ("Dials", after the app icon: a shield with a countdown dial): a ring for the time
/// left of an activation, a tinted rounded square for the source of a role.

extension SourceIcon {
    /// Tint of a source's square: Azure blue, Entra teal, PIM groups violet (text tokens: readable in their own tint).
    static func tint(_ source: RoleSource) -> Color {
        switch source {
        case .azureResource: Theme.accent
        case .entraRole: Theme.teal
        case .pimGroup: Theme.violet
        }
    }
}

/// Progress ring of an activation: the share of its window still left (`Countdown.fraction`), from the top,
/// clockwise. It sweeps in when shown and follows the store clock smoothly; static with Reduce Motion. Decorative:
/// the card that holds it speaks the time left.
struct RoleDial<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let value = reduceMotion || shown ? fraction : 0
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value)
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                        startAngle: .zero, endAngle: .degrees(360 * max(value, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: value)
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }
}

extension RoleDial where Center == EmptyView {
    init(fraction: Double, tint: Color, lineWidth: CGFloat = 8) {
        self.init(fraction: fraction, tint: tint, lineWidth: lineWidth) { EmptyView() }
    }
}

/// The dial of an activation with its source symbol in the middle: tinted by the time left (green, orange in the last
/// 15 minutes, red in the last 5).
struct ActivationDial: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    let size: CGFloat

    var body: some View {
        let remaining = assignment.endAt.map { $0.timeIntervalSince(store.now) }
        let fraction = Countdown.fraction(start: assignment.startAt, end: assignment.endAt, now: store.now) ?? 1
        RoleDial(fraction: fraction, tint: Theme.remaining(remaining), lineWidth: max(4, size / 11)) {
            Image(systemName: SourceIcon.name(assignment.source))
                .font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(Theme.remaining(remaining))
        }
        .frame(width: size, height: size)
    }
}

/// A role's source in a tinted rounded square (eligible rows, permanent cards, the roles list); VoiceOver reads its
/// type (« Azure »).
struct SourceBadge: View {
    let source: RoleSource
    var size: CGFloat = 34

    var body: some View {
        let tint = SourceIcon.tint(source)
        Image(systemName: SourceIcon.name(source))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(TypeTag.text(source))
    }
}

/// Card behind the hero and the active role cards.
struct DialCardBackground: ViewModifier {
    var radius: CGFloat = 18
    var glow: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                if let glow {
                    shape.fill(LinearGradient(colors: [glow.opacity(0.16), glow.opacity(0.02)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            .contentShape(shape)
    }
}

extension View {
    func dialCard(radius: CGFloat = 18, glow: Color? = nil) -> some View {
        modifier(DialCardBackground(radius: radius, glow: glow))
    }

    /// A card on its own list row: no row background or separator, the card's own spacing.
    func cardRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// No role active: the dial's outline and how to start one.
struct EmptyDialCard: View {
    @ScaledMetric(relativeTo: .title) private var dialSize: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            ZStack {
                Circle().stroke(Theme.track, style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [2, 9]))
                Image(systemName: "shield")
                    .font(.system(size: dialSize * 0.36, weight: .semibold))
                    .foregroundStyle(Theme.slate)
            }
            .frame(width: min(dialSize, 96), height: min(dialSize, 96))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("No active role").font(.headline)
                Text("Activate an eligible role below: its countdown shows here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dialCard()
        .accessibilityElement(children: .combine)
    }
}
