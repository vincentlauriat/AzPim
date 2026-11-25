import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen / banner and Dynamic Island of `RoleActivityAttributes`. The countdown is `Text(timerInterval:)`: it
/// ticks on its own, the app does not update the activity every minute (it cannot, without a push server).
struct RoleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoleActivityAttributes.self) { context in
            RoleActivityLockScreen(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(Color(uiColor: UIColor(hex: Theme.Tone.accent.dark)))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RoleSymbol(context: context).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RoleTimer(state: context.state, isStale: context.isStale)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.roleName).font(.headline).lineLimit(1)
                        Text(context.attributes.scopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        OthersLabel(count: context.state.otherActive)
                        Spacer()
                        ExtendButton(roleId: context.attributes.eligibleRoleId, isStale: context.isStale)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                RoleSymbol(context: context)
            } compactTrailing: {
                RoleTimer(state: context.state, isStale: context.isStale)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                RoleSymbol(context: context)
            }
            .keylineTint(ActivityTone.tint(for: context.state.endAt, isStale: context.isStale, dark: true))
        }
    }
}

/// Colours of the activity, from the app's tokens (`Theme.Tone`), resolved by hand: the Dynamic Island is always dark,
/// the lock screen follows the colour scheme.
enum ActivityTone {
    /// Green with time left, orange in the last 15 minutes, red in the last 5 (as `Theme.remaining`), grey once stale.
    /// Computed when the system draws the activity, which happens on each update: between updates only the countdown
    /// moves, so the colour can lag (it turns grey at the end through `staleDate`).
    static func tint(for endAt: Date, isStale: Bool, dark: Bool, now: Date = .now) -> Color {
        let left = endAt.timeIntervalSince(now)
        let tone: Theme.Tone = isStale || left <= 0 ? .slate : left <= 300 ? .danger : left <= 900 ? .warning : .active
        return Color(uiColor: UIColor(hex: tone.hex(dark: dark, increasedContrast: false)))
    }

    static func accent(dark: Bool) -> Color {
        Color(uiColor: UIColor(hex: Theme.Tone.accentFill.hex(dark: dark, increasedContrast: false)))
    }
}

private struct RoleActivityLockScreen: View {
    let context: ActivityViewContext<RoleActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoleSymbol(context: context).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.roleName).font(.headline).lineLimit(1)
                Text(context.attributes.scopeName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                OthersLabel(count: context.state.otherActive)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                RoleTimer(state: context.state, isStale: context.isStale)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ActivityTone.tint(for: context.state.endAt, isStale: context.isStale,
                                                       dark: colorScheme == .dark))
                    .frame(maxWidth: 110, alignment: .trailing)
                ExtendButton(roleId: context.attributes.eligibleRoleId, isStale: context.isStale)
            }
        }
        .padding(16)
    }
}

/// The source's symbol, tinted with the time left.
private struct RoleSymbol: View {
    let context: ActivityViewContext<RoleActivityAttributes>

    var body: some View {
        Image(systemName: context.attributes.sourceSymbol)
            .foregroundStyle(ActivityTone.tint(for: context.state.endAt, isStale: context.isStale, dark: true))
            .accessibilityHidden(true)
    }
}

/// Time left, ticking by itself; « Expired » once the end has passed (the range is clamped: an end in the past would
/// make an invalid range).
private struct RoleTimer: View {
    let state: RoleActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale || state.endAt <= .now {
            Text("Expired")
        } else {
            Text(timerInterval: Date.now...max(Date.now, state.endAt), countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct OthersLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count) other active roles").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct ExtendButton: View {
    let roleId: String
    let isStale: Bool

    /// A link, not an intent button: an intent runs in the background, where iOS may suspend AzPim between the
    /// deactivation and the re-activation of an Extend. The link opens the role's detail, whose Extend runs in the
    /// foreground (`MobileNavigation.openRole`).
    var body: some View {
        if !isStale, let url = WidgetSnapshot.roleURL(roleId) {
            Link(destination: url) {
                Label("Extend", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(ActivityTone.accent(dark: false))
        }
    }
}
