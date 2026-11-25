import AzPimCore
import SwiftUI

/// Activation duration in 15-minute steps, capped by the policy maximum, with 1 h / Max quick chips
/// (Activation Sheet and favorites).
struct DurationPicker: View {
    @Binding var minutes: Int
    let policyMax: String?
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif

    private var maxMinutes: Int { ActivationDuration.maxMinutes(policyMax: policyMax) }

    var body: some View {
        #if os(iOS)
        // iPhone at accessibility sizes: the stepper, then the chips under it (one per line when they do not fit).
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                stepper
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { chips }
                    VStack(alignment: .leading, spacing: 6) { chips }
                }
            }
        } else {
            HStack(spacing: 6) { stepper; chips }
        }
        #else
        HStack(spacing: 6) { stepper; chips }
        #endif
    }

    private var stepper: some View {
        Stepper {
            Text(label(minutes)).monospacedDigit().frame(minWidth: 70, alignment: .leading)
        } onIncrement: {
            minutes = ActivationDuration.step(minutes, upward: true, policyMax: policyMax)
        } onDecrement: {
            minutes = ActivationDuration.step(minutes, upward: false, policyMax: policyMax)
        }
        .accessibilityLabel("Duration")
        .accessibilityValue(label(minutes))
        .help("15-minute steps, up to the policy maximum (\(label(maxMinutes)))")
    }

    @ViewBuilder private var chips: some View {
        if maxMinutes > 60 { chip(label(60), value: 60) }
        chip(String(localized: "Max (\(label(maxMinutes)))"), value: maxMinutes)
    }

    @ViewBuilder private func chip(_ title: String, value: Int) -> some View {
        let button = Button(title) { minutes = value }.controlSize(.small)
        // The chip matching the current duration is filled.
        if minutes == value {
            button.buttonStyle(.borderedProminent).tint(Theme.accentFill).accessibilityAddTraits(.isSelected)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func label(_ value: Int) -> String { ISODuration.label(TimeInterval(value * 60)) }
}
