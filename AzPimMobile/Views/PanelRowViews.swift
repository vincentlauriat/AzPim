import AzPimCore
import SwiftUI

/// An activation (countdown, Deactivate) or a permanent assignment (read-only).
struct ActiveRoleRow: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    let alsoPermanent: Bool
    /// Nil for a permanent assignment.
    let deactivate: ((ActiveAssignment) -> Void)?

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { store.now.timeIntervalSince(assignment.startAt) < 300 }
    private var remaining: TimeInterval? { assignment.endAt.map { $0.timeIntervalSince(store.now) } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoleLabel(name: assignment.displayRoleName, scope: assignment.displayScopeName, source: assignment.source,
                      tenant: nil)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                if let remaining {
                    Text(Countdown.compact(remaining))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.remaining(remaining))
                        .accessibilityLabel(Countdown.spoken(remaining))
                } else {
                    Text("Permanent").font(.footnote).foregroundStyle(.secondary)
                }
                if alsoPermanent { Text("also permanent").font(.caption2).foregroundStyle(.secondary) }
                if let deactivate {
                    if store.isBusy(assignment) {
                        ProgressView()
                    } else {
                        Button("Deactivate", role: .destructive) { deactivate(assignment) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(tooRecent || store.isOffline)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        if let error = store.rowErrors[assignment.id] {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
    }
}

/// An eligible role: tap to open the Activation Sheet.
struct EligibleRoleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let waiting: ActivationRecord?
    let activate: (EligibleRole) -> Void

    var body: some View {
        Button {
            activate(role)
        } label: {
            HStack(spacing: 12) {
                RoleLabel(name: role.displayRoleName, scope: role.displayScopeName, source: role.source, tenant: nil)
                Spacer(minLength: 4)
                if store.busy.contains(role.id) {
                    ProgressView()
                } else if waiting?.status == .pendingApproval {
                    Label("Pending approval", systemImage: "hourglass").labelStyle(.iconOnly).foregroundStyle(Theme.warning)
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Activate…")
        if let error = store.rowErrors[role.id] {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
    }
}

/// Role name, scope and type tag.
struct RoleLabel: View {
    let name: String
    let scope: String
    let source: RoleSource
    let tenant: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                TypeTag(source: source)
                Text(scope).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
