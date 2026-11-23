import AzPimCore
import SwiftUI

/// Search field at the top of the panel; ⌘F focuses it, Escape clears it.
struct PanelSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Search roles", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                // Escape clears a search; with nothing typed it goes on to close the panel.
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .accessibilityLabel("Search roles by name, scope or group")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .card()
        // ⌘F: an invisible button (a hidden one can lose its shortcut).
        .background(
            Button("Search") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// Compact hero card: one line « 2 active · next expiry in 42m · 1 pending » and the refresh status; when offline, a
/// second line « Offline · data from 10:42 ».
struct CompactHeroCard: View {
    @Environment(RoleStore.self) private var store
    let summary: HeroSummary
    /// `summary.line` with the time left in words, for VoiceOver.
    let spokenLine: String
    let activeCount: Int
    /// Seconds left on the activation ending first (colors the expiry segment).
    let remaining: TimeInterval?
    /// « Reader · Tenant Root Group » of the activation ending first (tooltip).
    let nextRole: String?
    let signedIn: Bool

    private var hasActive: Bool { activeCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: hasActive ? "key.horizontal.fill" : "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hasActive ? Theme.active : Color.secondary)
                // A second line rather than a cut summary (« prochaine expiration dans 3 h 24 min » is long).
                line
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
                    .help(nextRole.map { String(localized: "Next expiry: \($0)") } ?? "")
                Spacer(minLength: 6)
                // Never truncated by a long summary.
                statusLine.fixedSize().layoutPriority(1)
            }
            if store.isOffline {
                Label(offlineText, systemImage: "wifi.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .help("Actions are disabled until the network is back")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .announcesChanges(store.isOffline ? offlineText : nil)
    }

    private var accessibilityText: String {
        guard signedIn else { return String(localized: "Not signed in") }
        let next = nextRole.map { String(localized: ", ending first: \($0)") } ?? ""
        let offline = store.isOffline ? ", \(offlineText)" : ""
        return spokenLine + next + offline
    }

    private var line: Text {
        guard signedIn else { return Text("Not signed in").foregroundStyle(.secondary) }
        var text = Text(summary.active).foregroundStyle(hasActive ? Theme.active : Color.secondary)
        if let expiry = summary.expiry {
            let color = (remaining ?? .infinity) <= 900 ? Theme.remaining(remaining) : Color.primary
            text = text + Text(" · ").foregroundStyle(.secondary) + Text(expiry).foregroundStyle(color)
        }
        if let pending = summary.pending {
            text = text + Text(" · ").foregroundStyle(.secondary) + Text(pending).foregroundStyle(Theme.warning)
        }
        return text
    }

    @ViewBuilder private var statusLine: some View {
        if store.isRefreshing {
            ProgressView().controlSize(.small)
        } else if store.isOffline {
            EmptyView()   // its own line below
        } else if let last = store.lastRefresh {
            Text(last.appFormatted(date: .omitted, time: .shortened))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help("Updated at \(last.appFormatted(date: .omitted, time: .shortened))")
        }
    }

    private var offlineText: String {
        guard let last = store.lastOnline else { return String(localized: "Offline") }
        return String(localized: "Offline · data from \(last.appFormatted(date: .omitted, time: .shortened))")
    }
}
