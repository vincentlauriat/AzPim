import SwiftUI

/// Panel status under the search field: the last keyboard action's message, then the last result of a sheet or a
/// link (also notified when notifications are allowed, 1.0 item 9).
struct PanelStatusLines: View {
    @Environment(RoleStore.self) private var store
    let keyboardMessage: String?

    var body: some View {
        if let keyboardMessage {
            Text(keyboardMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
        if let result = store.lastResult, result.isRecent(at: store.now) {
            ResultStatusLine(result: result)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
    }
}

/// Inline status of the last action result (panel, Roles Window): the same text as its notification.
struct ResultStatusLine: View {
    let result: ActionResult

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(result.body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
