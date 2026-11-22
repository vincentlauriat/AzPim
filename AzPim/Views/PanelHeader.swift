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
                .onExitCommand { query = "" }
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

/// Compact hero card: one line « 2 active · next expiry in 42m · 1 pending » and the refresh status.
struct CompactHeroCard: View {
    @Environment(RoleStore.self) private var store
    let summary: HeroSummary
    let activeCount: Int
    /// Seconds left on the activation ending first (colors the expiry segment).
    let remaining: TimeInterval?
    /// « Reader · Tenant Root Group » of the activation ending first (tooltip).
    let nextRole: String?
    let signedIn: Bool

    private var hasActive: Bool { activeCount > 0 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasActive ? "key.horizontal.fill" : "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hasActive ? Theme.active : Color.secondary)
            line
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(nextRole.map { "Next expiry: \($0)" } ?? "")
            Spacer(minLength: 6)
            statusLine
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .card()
        .accessibilityElement(children: .combine)
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
            Label("Offline", systemImage: "wifi.slash").font(.system(size: 11)).foregroundStyle(Theme.warning)
                .lineLimit(1)
                .help(offlineHelp)
        } else if let last = store.lastRefresh {
            Text(last.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help("Updated at \(last.formatted(date: .omitted, time: .shortened))")
        }
    }

    private var offlineHelp: String {
        let data = store.lastOnline.map { "Data from \($0.formatted(date: .omitted, time: .shortened)). " } ?? ""
        return data + "Actions are disabled until the network is back"
    }
}
