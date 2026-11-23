import AzPimCore
import SwiftUI

/// VoiceOver announcements of what appears without moving the focus: errors, the offline line, activation results.
@MainActor
enum Announcer {
    static func post(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// An activation sent: what happened to it. A failure is announced by its row or sheet (`rowErrors`).
    static func post(activation status: RequestStatus?, role: String) {
        switch status {
        case .provisioned?: post(String(localized: "\(role) activated."))
        case .pendingApproval?: post(String(localized: "Request sent — pending approval."))
        case .some: post(String(localized: "Request sent — not confirmed yet. Check the panel in a moment."))
        case nil: break
        }
    }
}

extension View {
    /// Reads `text` aloud with VoiceOver each time it changes to a new non-empty value.
    func announcesChanges(_ text: String?) -> some View {
        onChange(of: text) { _, new in Announcer.post(new) }
    }
}
