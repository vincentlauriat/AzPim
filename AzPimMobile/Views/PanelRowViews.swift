import AzPimCore
import SwiftUI

extension EligibleRole {
    /// Why it cannot be activated now (in progress, a request waiting, offline), as the detail and the eligible row
    /// show it; nil when it can. Duration and form are the sheet's: only the state is checked. Read once per body
    /// (`store.now` follows the store clock: a sent request's 15-minute window).
    @MainActor func activateBlock(in store: RoleStore) -> ActivationBlock? {
        ActivationBlock.reason(.init(inProgress: store.busy.contains(id),
                                     pending: store.waitingRequest(for: self, at: store.now) != nil,
                                     offline: store.isOffline, minutes: ActivationDuration.minMinutes(policyMax: maxDuration),
                                     policyMax: maxDuration, requiresJustification: false))
    }
}

/// An eligible role: its source square, name and scope, an Activate button and a chevron. Tap the row → the role
/// detail; Activate → the Activation Sheet. One VoiceOver element: Details by default, Activate… as an action.
struct EligibleRoleRow: View {
    @Environment(RoleStore.self) private var store
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 34
    let role: EligibleRole
    let waiting: ActivationRecord?
    /// The haptic's trigger when the context menu added the role to a favorite.
    @State private var addedCount = 0

    private var isPending: Bool { waiting?.status == .pendingApproval }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { badge; title }
                    HStack { trailing; Spacer(); Chevron() }
                }
            } else {
                HStack(spacing: 12) {
                    badge
                    title
                    Spacer(minLength: 4)
                    trailing
                    Chevron()
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { navigation.selection = role.id }
        .contextMenu {
            menu
            // Not in the VoiceOver actions (buttons only): VoiceOver adds from the role's detail.
            Menu {
                AddToFavoriteMenu(role: role) { favorite in
                    addedCount += 1
                    VoiceOverAnnouncer.post(String(localized: "Added to “\(favorite.name)”"))
                }
            } label: {
                Label("Add to favorite", systemImage: "star")
            }
        }
        .sensoryFeedback(.success, trigger: addedCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(role.displayRoleName), \(role.displayScopeName), \(TypeTag.text(role.source))"))
        .accessibilityValue(spokenState)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { navigation.selection = role.id }
        .accessibilityActions { menu }
        if let error = store.rowErrors[role.id] {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
    }

    /// In progress, waiting for an approver, or why Activate is unavailable (offline, a request just sent).
    private var spokenState: Text {
        if store.busy.contains(role.id) { return Text("In progress") }
        if isPending { return Text("Pending approval") }
        return role.activateBlock(in: store).map { Text(verbatim: $0.message) } ?? Text(verbatim: "")
    }

    private var badge: some View {
        SourceBadge(source: role.source, size: min(badgeSize, 56))
    }

    private var title: some View {
        RoleTitle(name: role.displayRoleName, scope: role.displayScopeName)
    }

    @ViewBuilder private var trailing: some View {
        if store.busy.contains(role.id) {
            ProgressView()
        } else if isPending {
            Label("Pending approval", systemImage: "hourglass")
                .font(.footnote.weight(.semibold)).labelStyle(.iconOnly)
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.warning.opacity(0.14), in: Capsule())
        } else {
            Button("Activate") { navigation.activating = role }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                .tint(Theme.accentFill)
                .disabled(role.activateBlock(in: store) != nil)
        }
    }

    @ViewBuilder private var menu: some View {
        if role.activateBlock(in: store) == nil {
            Button { navigation.activating = role } label: { Label("Activate…", systemImage: "bolt.fill") }
        }
        Button { navigation.selection = role.id } label: { Label("Details", systemImage: "info.circle") }
    }
}

/// A favorite as a capsule: star and name, a spinner while it runs. Tap → runs it (`RolesScreen.start`).
struct FavoriteChip: View {
    let name: String
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "star.fill").font(.caption.weight(.semibold))
                }
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.violet)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.violet.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(running ? Text("In progress") : Text(verbatim: ""))
        .accessibilityHint("Activates the roles of this favorite")
    }
}

/// Role name over its scope.
struct RoleTitle: View {
    let name: String
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.body.weight(.medium)).lineLimit(2)
            Text(scope).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}
