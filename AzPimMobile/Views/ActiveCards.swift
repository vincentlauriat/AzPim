import AzPimCore
import SwiftUI

extension ActiveAssignment {
    /// The roles list row this assignment opens (`RoleRow.id`): an activation's eligible role, a permanent assignment
    /// itself. Nil for an activation whose eligibility is unknown (its source failed, or it was removed): no detail.
    var detailRowId: String? { assignmentType == .activated ? eligibleRole?.id : id }

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    func isTooRecentToDeactivate(at now: Date) -> Bool { now.timeIntervalSince(startAt) < 300 }

    /// VoiceOver: « Contributor, rg-app-prod, 3 hours, 15 minutes left », or « …, Permanent ».
    func spokenSummary(now: Date, alsoPermanent: Bool) -> String {
        var parts = [displayRoleName, displayScopeName]
        if let endAt {
            parts.append(String(localized: "\(Countdown.spoken(endAt.timeIntervalSince(now))) left"))
        } else {
            parts.append(String(localized: "Permanent"))
        }
        if alsoPermanent { parts.append(String(localized: "also permanent")) }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver value of its card: in progress, and the row's last error.
    @MainActor func spokenState(in store: RoleStore) -> String {
        var parts: [String] = []
        if store.isBusy(self) { parts.append(String(localized: "In progress")) }
        if let error = store.rowErrors[id] { parts.append(error) }
        return parts.joined(separator: ", ")
    }
}

/// Extend, Deactivate… and Details of an active role: context menus and VoiceOver actions of its card. A function of
/// the card's store and navigation, not a view reading the environment (menus and accessibility actions may not get
/// it).
@MainActor @ViewBuilder
func activeRoleActions(_ assignment: ActiveAssignment, store: RoleStore, navigation: MobileNavigation) -> some View {
    if assignment.assignmentType == .activated, !store.isBusy(assignment), !store.isOffline {
        if let role = assignment.eligibleRole {
            Button { navigation.extend(role, store: store) } label: { Label("Extend", systemImage: "clock.arrow.circlepath") }
        }
        if !assignment.isTooRecentToDeactivate(at: store.now) {
            Button(role: .destructive) { navigation.deactivating = assignment } label: {
                Label("Deactivate…", systemImage: "stop.circle")
            }
        }
    }
    if let id = assignment.detailRowId {
        Button { navigation.selection = id } label: { Label("Details", systemImage: "info.circle") }
    }
}

extension View {
    /// A card that opens a role detail: tap, button trait and default VoiceOver action; none without a detail.
    @ViewBuilder func opensDetail(_ id: String?, navigation: MobileNavigation) -> some View {
        if let id {
            onTapGesture { navigation.selection = id }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { navigation.selection = id }
        } else {
            self
        }
    }
}

/// The activation that ends first, on top of the iPhone panel: a large dial, the role, the time left, Extend and
/// Deactivate. Tap → the role detail. One VoiceOver element, its buttons as actions.
struct HeroCard: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var dialSize: CGFloat = 92
    let assignment: ActiveAssignment
    let alsoPermanent: Bool

    private var remaining: TimeInterval? { assignment.endAt.map { $0.timeIntervalSince(store.now) } }
    private var stacked: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            buttons
            if let role = assignment.eligibleRole, let result = navigation.extendResults[role.id] {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        .padding(18)
        .dialCard(radius: 24, glow: Theme.remaining(remaining))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroLabel)
        .accessibilityValue(assignment.spokenState(in: store))
        .opensDetail(assignment.detailRowId, navigation: navigation)
        .accessibilityActions { activeRoleActions(assignment, store: store, navigation: navigation) }
    }

    /// The summary and the last Extend result (also announced when it comes).
    private var heroLabel: String {
        let summary = assignment.spokenSummary(now: store.now, alsoPermanent: alsoPermanent)
        guard let role = assignment.eligibleRole, let result = navigation.extendResults[role.id] else { return summary }
        return "\(summary), \(result)"
    }

    private var summary: some View {
        stacked {
            ActivationDial(assignment: assignment, size: min(dialSize, 132))
            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.displayRoleName).font(.title3.weight(.semibold)).lineLimit(3)
                Text(assignment.displayScopeName).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                if let remaining {
                    Text(Countdown.long(remaining))
                        .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.remaining(remaining))
                        .padding(.top, 4)
                }
                if alsoPermanent { Text("also permanent").font(.caption).foregroundStyle(.secondary) }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                if assignment.detailRowId != nil { Chevron() }
            }
        }
    }

    /// Side by side, stacked at accessibility sizes.
    @ViewBuilder private var buttons: some View {
        if store.isBusy(assignment) {
            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
        } else {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                if let role = assignment.eligibleRole {
                    Button { navigation.extend(role, store: store) } label: {
                        ActionTitle(title: "Extend", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accentFill)
                    .disabled(store.isOffline)
                }
                Button(role: .destructive) { navigation.deactivating = assignment } label: {
                    ActionTitle(title: "Deactivate", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered).tint(Theme.danger)
                .disabled(assignment.isTooRecentToDeactivate(at: store.now) || store.isOffline)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }
}

/// A hero button's symbol and title, on one line, as wide as the button may be.
private struct ActionTitle: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }
}

/// Another active role, in the grid under the hero: a small dial and the time left, or the source and « Permanent ».
/// Tap → the role detail; Extend and Deactivate on the card; also in its context menu and VoiceOver actions.
struct ActiveRoleCard: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @ScaledMetric(relativeTo: .body) private var dialSize: CGFloat = 46
    let assignment: ActiveAssignment
    let alsoPermanent: Bool

    private var remaining: TimeInterval? { assignment.endAt.map { $0.timeIntervalSince(store.now) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if assignment.endAt != nil {
                    ActivationDial(assignment: assignment, size: min(dialSize, 72))
                } else {
                    SourceBadge(source: assignment.source, size: min(dialSize, 72))
                }
                Spacer(minLength: 4)
                actions
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.displayRoleName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(assignment.displayScopeName).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if alsoPermanent { Text("also permanent").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            status
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .dialCard()
        .contextMenu { activeRoleActions(assignment, store: store, navigation: navigation) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(assignment.spokenSummary(now: store.now, alsoPermanent: alsoPermanent))
        .accessibilityValue(assignment.spokenState(in: store))
        .opensDetail(assignment.detailRowId, navigation: navigation)
        .accessibilityActions { activeRoleActions(assignment, store: store, navigation: navigation) }
    }

    /// Extend and Deactivate of an activation, as small symbol buttons (hidden: the card's VoiceOver actions).
    @ViewBuilder private var actions: some View {
        if assignment.assignmentType == .activated {
            if store.isBusy(assignment) {
                ProgressView()
            } else {
                HStack(spacing: 8) {
                    if let role = assignment.eligibleRole {
                        Button { navigation.extend(role, store: store) } label: {
                            CircleSymbol(name: "clock.arrow.circlepath", tint: Theme.accent)
                        }
                        .disabled(store.isOffline)
                        .accessibilityLabel("Extend")
                    }
                    Button(role: .destructive) { navigation.deactivating = assignment } label: {
                        CircleSymbol(name: "stop.fill", tint: Theme.danger)
                    }
                    .disabled(assignment.isTooRecentToDeactivate(at: store.now) || store.isOffline)
                    .accessibilityLabel("Deactivate")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let remaining {
            Text(Countdown.compact(remaining))
                .font(.system(.headline, design: .rounded, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.remaining(remaining))
        } else {
            Text("Permanent").font(.subheadline.weight(.medium)).foregroundStyle(Theme.slate)
        }
    }
}

/// A card's small action: a symbol in a tinted circle, dimmed when disabled.
private struct CircleSymbol: View {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 32
    let name: String
    let tint: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: min(size, 48) * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: min(size, 48), height: min(size, 48))
            .background(tint.opacity(0.14), in: Circle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Trailing chevron of a row or card that opens the role detail.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
