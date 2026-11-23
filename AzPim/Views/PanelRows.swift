import AppKit
import AzPimCore
import SwiftUI

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

enum SourceIcon {
    static func name(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: "cloud"
        case .entraRole: "person.badge.key"
        case .pimGroup: "person.3"
        }
    }
}

struct EligibleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let isActive: Bool
    /// Status of a request still waiting for this role (pending approval or sent), if any.
    let pending: RequestStatus?
    /// Selected with the keyboard (↑/↓).
    var selected = false
    /// VoiceOver « Activate now »: the quick activation (⌥-click, Return), nil to leave the action out.
    var activateNow: (() -> Void)?
    /// Opens the Activation Sheet (the Activate button).
    let activate: () -> Void

    /// The Activate button is shown and enabled: no request running or waiting, not active, online.
    private var canActivate: Bool { !store.busy.contains(role.id) && !isActive && pending == nil && !store.isOffline }

    private var spokenState: SpokenRoleState {
        if store.busy.contains(role.id) { return .busy }
        if isActive { return .active(remaining: nil) }
        switch pending {
        case .sent?: return .sent
        case .some: return .pendingApproval
        case nil: return .eligible
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // VoiceOver: the text is one element with the row's label and actions; the button stays a child, for
                // Full Keyboard Access.
                HStack(spacing: 8) {
                    Image(systemName: SourceIcon.name(role.source)).frame(width: 22).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.displayRoleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(role.memberType == .group ? String(localized: "\(role.displayScopeName) · via group") : role.displayScopeName)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpokenRole.label(role: role.displayRoleName, source: role.source, scope: role.displayScopeName,
                                                     state: spokenState, viaGroup: role.memberType == .group,
                                                     error: store.rowErrors[role.id]))
                .accessibilityHint(canActivate ? String(localized: "Opens the Activation Sheet") : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityAction { if canActivate { activate() } }
                .accessibilityActions {
                    if canActivate {
                        Button("Activate…", action: activate)
                        if let activateNow { Button("Activate now", action: activateNow) }
                    }
                }
                Spacer()
                if store.busy.contains(role.id) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else if isActive {
                    Text("Active").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.active)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.active.opacity(0.14), in: Capsule())
                        .accessibilityHidden(true)
                } else if let pending {
                    Label(pending == .sent ? "Sent" : "Pending", systemImage: "clock")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                        .help(pending == .sent ? "Not confirmed yet — refreshes in a moment" : "Waiting for approval — see History")
                        .accessibilityHidden(true)
                } else {
                    Button("Activate", action: activate)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accentFill)
                        .controlSize(.small)
                        .disabled(store.isOffline)
                        .help("Activate… — ⌥-click: activate now with the default duration")
                        .accessibilityLabel(String(localized: "Activate \(role.displayRoleName)"))
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
                    .accessibilityHidden(true)   // read with the row's label
            }
        }
        .keyboardSelected(selected)
        .accessibilityElement(children: .contain)
    }
}

struct ActiveRow: View {
    @Environment(RoleStore.self) private var store
    /// The activation: Deactivate and the countdown always target it, even when the role is also held permanently.
    let assignment: ActiveAssignment
    /// The same role is also assigned permanently (merged into this row).
    var alsoPermanent = false
    var showTypeTag = false
    /// Selected with the keyboard (↑/↓).
    var selected = false
    /// ⌫ on the selected row asks the same question as the button.
    var keyboardConfirm: Binding<Bool>?
    /// VoiceOver « Activate… » (the keyboard's ⌘Return); nil leaves the action out.
    var openSheet: (() -> Void)?
    @State private var confirming = false

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirming || keyboardConfirm?.wrappedValue == true },
                set: { shown in
                    confirming = shown
                    if !shown { keyboardConfirm?.wrappedValue = false }
                })
    }

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { Date.now.timeIntervalSince(assignment.startAt) < 300 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                summary
                    .layoutPriority(1)   // the name gets the room first; the countdown and button keep their size
                Spacer(minLength: 4)
                if let end = assignment.endAt {
                    let remaining = end.timeIntervalSince(store.now)
                    Text(Countdown.compact(remaining))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Theme.remaining(remaining))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.remaining(remaining).opacity(0.14), in: Capsule())
                        .help(Countdown.long(remaining))
                        .accessibilityHidden(true)   // spoken in words, to the minute, by the row's label
                }
                if store.isBusy(assignment) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    deactivateButton
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
                    .accessibilityHidden(true)   // read with the row's label
            }
        }
        .keyboardSelected(selected)
        .accessibilityElement(children: .contain)
    }

    /// Icon, name, type and scope: for VoiceOver the row's element, with its label and actions.
    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: SourceIcon.name(assignment.source)).frame(width: 22).foregroundStyle(Theme.active)
            VStack(alignment: .leading, spacing: 1) {
                // The role name keeps the full width; the type tag and the scope share the second line.
                Text(assignment.displayRoleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if showTypeTag { TypeTag(source: assignment.source) }
                    // "Directory" repeats the Entra tag: hide it so "also permanent" fits beside the countdown.
                    if !(showTypeTag && assignment.source == .entraRole && assignment.scope == "/") {
                        Text(assignment.displayScopeName).lineLimit(1).truncationMode(.middle)
                    }
                    if alsoPermanent {
                        Label("also permanent", systemImage: "lock").labelStyle(.titleAndIcon).imageScale(.small)
                            .lineLimit(1).fixedSize()
                            .help("Also assigned permanently: deactivating ends the activation only")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpokenRole.label(role: assignment.displayRoleName, source: assignment.source,
                                             scope: assignment.displayScopeName,
                                             state: store.isBusy(assignment) ? .busy
                                                 : .active(remaining: assignment.endAt?.timeIntervalSince(store.now)),
                                             alsoPermanent: alsoPermanent, error: store.rowErrors[assignment.id]))
        .accessibilityAddTraits(selected ? [.isSelected, .updatesFrequently] : .updatesFrequently)
        .accessibilityHint(store.isBusy(assignment) ? "" : String(localized: "Extend or deactivate from the actions"))
        .accessibilityAction { if !store.isBusy(assignment) { askToDeactivate() } }
        .accessibilityActions {
            if !store.isBusy(assignment) {
                if let role = assignment.eligibleRole { Button("Extend") { extend(role) } }
                Button("Deactivate…", action: askToDeactivate)
                if let openSheet { Button("Activate…", action: openSheet) }
            }
        }
    }

    private var deactivateButton: some View {
        Button {
            confirming = true
        } label: {
            Label("Deactivate \(assignment.displayRoleName)", systemImage: "stop.circle.fill").labelStyle(.iconOnly)
                .font(.system(size: 16))
                .foregroundStyle(tooRecent ? Color.secondary : Theme.danger)
        }
        .buttonStyle(.borderless)
        .disabled(tooRecent || store.isOffline)
        .help(tooRecent ? "Can't deactivate within 5 minutes of activation" : "Deactivate")
        .popover(isPresented: confirmShown) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Deactivate \(assignment.displayRoleName)?").font(.headline)
                Text(assignment.displayScopeName).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmShown.wrappedValue = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Deactivate", role: .destructive) {
                        confirmShown.wrappedValue = false
                        let id = assignment.id
                        Task {
                            if await !store.deactivate(assignment) { VoiceOverAnnouncer.post(store.rowErrors[id]) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    /// As ⇧Return: says it started, then how it ended (its errors included).
    private func extend(_ role: EligibleRole) {
        VoiceOverAnnouncer.post(String(localized: "Extending \(role.displayRoleName)…"))
        Task { VoiceOverAnnouncer.post(await store.extend(eligibleRoleId: role.id)) }
    }

    /// The button's question, or why it is disabled.
    private func askToDeactivate() {
        if tooRecent {
            VoiceOverAnnouncer.post(String(localized: "Can't deactivate within 5 minutes of activation."))
        } else if store.isOffline {
            VoiceOverAnnouncer.post(ActivationBlock.offline.message)
        } else {
            confirming = true
        }
    }
}

/// A permanent (non-PIM) role assignment: read-only, no countdown, no action.
struct PermanentRow: View {
    let assignment: ActiveAssignment
    let showAccount: Bool
    var showTypeTag = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SourceIcon.name(assignment.source)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(assignment.displayRoleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if showTypeTag { TypeTag(source: assignment.source) }
                    Text(showAccount ? "\(assignment.displayScopeName) · \(assignment.account?.upn ?? "")" : assignment.displayScopeName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: "lock").imageScale(.small).foregroundStyle(.tertiary)
                .help("Permanent assignment, managed by your administrator")
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpokenRole.label(role: assignment.displayRoleName, source: assignment.source,
                                             scope: assignment.displayScopeName, state: .permanent,
                                             account: showAccount ? assignment.account?.upn : nil))
    }
}

/// Favorite chips and the last run result (T4.2).
struct FavoriteChips: View {
    @Environment(RoleStore.self) private var store
    let favorites: [Favorite]
    /// A role needs a ticket, or a justification it does not have: the grouped sheet asks first.
    let ask: (FavoriteRunRequest) -> Void
    /// Favorites whose roles and policies are being read before the run or the grouped sheet.
    @State private var checking: Set<UUID> = []

    var body: some View {
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(favorites) { favorite in
                            Button {
                                Task { await start(favorite) }
                            } label: {
                                HStack(spacing: 4) {
                                    if store.runningFavorites.contains(favorite.id) || checking.contains(favorite.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "star.fill").imageScale(.small).accessibilityHidden(true)
                                    }
                                    Text(favorite.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.violet)
                            .controlSize(.regular)
                            .disabled(favorite.items.isEmpty || store.runningFavorites.contains(favorite.id)
                                      || checking.contains(favorite.id) || store.isOffline)
                            .help("Activate \(favorite.items.count) roles")
                        }
                    }
                }
                if let toast = store.favoriteToast {
                    let name = favorites.first { $0.id == toast.favoriteId }?.name ?? String(localized: "Favorite")
                    HStack(alignment: .top) {
                        Text("\(name): \(toast.text)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button {
                            store.favoriteToast = nil
                        } label: {
                            Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly).imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

extension FavoriteChips {
    /// Reads the roles once: runs at once, or hands them to the grouped sheet.
    private func start(_ favorite: Favorite) async {
        guard checking.insert(favorite.id).inserted else { return }
        let roles = await store.favoriteRolesToSend(favorite)
        checking.remove(favorite.id)
        if store.favoriteNeeds(roles).any {
            ask(FavoriteRunRequest(favorite: favorite, roles: roles))
        } else {
            await store.run(favorite)
        }
    }
}
