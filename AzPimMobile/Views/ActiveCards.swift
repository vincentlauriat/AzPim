import AzPimCore
import SwiftUI

extension ActiveAssignment {
    /// The roles list row this assignment opens (`RoleRow.id`): an activation's eligible role, a permanent assignment
    /// itself. Nil for an activation whose eligibility is unknown (its source failed, or it was removed): no detail.
    var detailRowId: String? { assignmentType == .activated ? eligibleRole?.id : id }

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
    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { store.now.timeIntervalSince(assignment.startAt) < 300 }
    private var stacked: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            buttons
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        .padding(18)
        .dialCard(radius: 24, glow: Theme.remaining(remaining))
        .onTapGesture { open() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(assignment.spokenSummary(now: store.now, alsoPermanent: alsoPermanent))
        .accessibilityAddTraits(assignment.detailRowId != nil ? .isButton : [])
        .accessibilityAction { open() }
        .accessibilityActions { ActiveRoleMenu(assignment: assignment) }
    }

    private func open() {
        if let id = assignment.detailRowId { navigation.selection = id }
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
                .disabled(tooRecent || store.isOffline)
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
/// Tap → the role detail; Deactivate on the card; Extend and Details in its context menu and VoiceOver actions.
struct ActiveRoleCard: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @ScaledMetric(relativeTo: .body) private var dialSize: CGFloat = 46
    let assignment: ActiveAssignment
    let alsoPermanent: Bool

    private var remaining: TimeInterval? { assignment.endAt.map { $0.timeIntervalSince(store.now) } }
    private var tooRecent: Bool { store.now.timeIntervalSince(assignment.startAt) < 300 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if assignment.endAt != nil {
                    ActivationDial(assignment: assignment, size: min(dialSize, 72))
                } else {
                    SourceBadge(source: assignment.source, size: min(dialSize, 72))
                }
                Spacer(minLength: 4)
                deactivate
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.displayRoleName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(assignment.displayScopeName).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
        .onTapGesture { if let id = assignment.detailRowId { navigation.selection = id } }
        .contextMenu { ActiveRoleMenu(assignment: assignment) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(assignment.spokenSummary(now: store.now, alsoPermanent: alsoPermanent))
        .accessibilityAddTraits(assignment.detailRowId != nil ? .isButton : [])
        .accessibilityAction { if let id = assignment.detailRowId { navigation.selection = id } }
        .accessibilityActions { ActiveRoleMenu(assignment: assignment) }
    }

    @ViewBuilder private var deactivate: some View {
        if assignment.assignmentType == .activated {
            if store.isBusy(assignment) {
                ProgressView()
            } else {
                Button(role: .destructive) { navigation.deactivating = assignment } label: {
                    Image(systemName: "stop.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless).tint(Theme.danger)
                .disabled(tooRecent || store.isOffline)
                .accessibilityLabel("Deactivate")
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
        if alsoPermanent { Text("also permanent").font(.caption2).foregroundStyle(.secondary) }
    }
}

/// Extend, Deactivate… and Details of an active role: context menus and VoiceOver actions of its card.
struct ActiveRoleMenu: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    let assignment: ActiveAssignment

    var body: some View {
        if assignment.assignmentType == .activated, !store.isBusy(assignment) {
            if let role = assignment.eligibleRole, !store.isOffline {
                Button { navigation.extend(role, store: store) } label: { Label("Extend", systemImage: "clock.arrow.circlepath") }
            }
            if store.now.timeIntervalSince(assignment.startAt) >= 300, !store.isOffline {
                Button(role: .destructive) { navigation.deactivating = assignment } label: {
                    Label("Deactivate…", systemImage: "stop.circle")
                }
            }
        }
        if let id = assignment.detailRowId {
            Button { navigation.selection = id } label: { Label("Details", systemImage: "info.circle") }
        }
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
