import AppKit
import AzPimCore
import SwiftUI

/// Time left on an activation, by the system formatters in the app's language (rounded down to the minute, to the
/// second in the last 5). Two styles: `compact` in the countdown capsules, `full` in sentences.
enum Countdown {
    /// Menu bar: « 5:16 » (hours:minutes), « 3:12 » (minutes:seconds) in the last 5 minutes.
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 300 { return clock(total) }
        return Duration.seconds(total)
            .formatted(.time(pattern: .hourMinute(padHourToLength: 1, roundSeconds: .down)).locale(AppLanguage.locale))
    }

    /// Capsules (panel rows, palette): « 5h 16m » / « 5h 16min », « 42m », « 3:12 » in the last 5 minutes.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 300 ? clock(total) : units(total, width: .narrow)
    }

    /// Sentences (hero line, tiles, tooltips): « 5 hr 16 min » / « 5 h 16 min », « 3:12 » in the last 5 minutes.
    static func full(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 300 ? clock(total) : units(total, width: .condensedAbbreviated)
    }

    /// « 5 hr 16 min left » / « Reste 5 h 16 min ».
    static func long(_ seconds: TimeInterval) -> String {
        String(localized: "\(full(seconds)) left")
    }

    /// VoiceOver: « 5 hours, 16 minutes ».
    static func spoken(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return String(localized: "unknown") }
        return units(max(0, Int(seconds)), width: .wide)
    }

    private static func clock(_ total: Int) -> String {
        Duration.seconds(total).formatted(.time(pattern: .minuteSecond).locale(AppLanguage.locale))
    }

    private static func units(_ total: Int, width: Duration.UnitsFormatStyle.UnitWidth) -> String {
        Duration.seconds(total / 60 * 60).formatted(.units(allowed: [.hours, .minutes], width: width).locale(AppLanguage.locale))
    }

    static func color(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return .primary }
        if seconds <= 300 { return .red }
        if seconds <= 900 { return .orange }
        return .primary
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(role.source)).frame(width: 22).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.displayRoleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(role.memberType == .group ? String(localized: "\(role.displayScopeName) · via group") : role.displayScopeName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if store.busy.contains(role.id) {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.active)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.active.opacity(0.14), in: Capsule())
                } else if let pending {
                    Label(pending == .sent ? "Sent" : "Pending", systemImage: "clock")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                        .help(pending == .sent ? "Not confirmed yet — refreshes in a moment" : "Waiting for approval — see History")
                } else {
                    Button("Activate", action: activate)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        .disabled(store.isOffline)
                        .help("Activate… — ⌥-click: activate now with the default duration")
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
            }
        }
        .keyboardSelected(selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                }
                if store.isBusy(assignment) {
                    ProgressView().controlSize(.small)
                } else {
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
                                    Task { await store.deactivate(assignment) }
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(14)
                        .frame(width: 260)
                    }
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
            }
        }
        .keyboardSelected(selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(assignment.displayRoleName), \(assignment.displayScopeName), permanent")
    }
}

/// Panel banner for a refresh problem (AppFlow › Empty and blocked states).
struct ErrorBanner: View {
    let kind: ErrorKind
    let account: String?
    /// Opens the Microsoft sign-in (MSAL accounts): background refreshes never open it on their own.
    var onSignIn: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(account.map { String(localized: "\($0): \(kind.message)") } ?? kind.message).font(.system(size: 12))
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.warning)
            }
            .textSelection(.enabled)
            if let command = kind.command {
                Button(copied ? "Copied" : "Copy “\(command)”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            if case .interactionRequired = kind, let onSignIn {
                Button("Sign in…", action: onSignIn).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch kind {
        case .throttled: "hourglass"
        case .cliExpired, .cliStepUp, .cliNotFound, .interactionRequired: "person.crop.circle.badge.exclamationmark"
        case .forbidden: "hand.raised.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}

/// Favorite chips and the last run result (T4.2).
struct FavoriteChips: View {
    @Environment(RoleStore.self) private var store
    let favorites: [Favorite]

    var body: some View {
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(favorites) { favorite in
                            Button {
                                Task { await store.run(favorite) }
                            } label: {
                                HStack(spacing: 4) {
                                    if store.runningFavorites.contains(favorite.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "star.fill").imageScale(.small)
                                    }
                                    Text(favorite.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.violet)
                            .controlSize(.regular)
                            .disabled(favorite.items.isEmpty || store.runningFavorites.contains(favorite.id) || store.isOffline)
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
