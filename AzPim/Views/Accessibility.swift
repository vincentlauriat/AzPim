import SwiftUI

/// VoiceOver announcements of what appears without moving the focus: errors, the offline line, Extend progress.
/// Activation and favorite results are announced centrally, only when no notification was posted.
@MainActor
enum VoiceOverAnnouncer {
    static func post(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        #if DEBUG && os(macOS)
        if SnapshotRunner.directory != nil { return }   // renders never speak
        #endif
        AccessibilityNotification.Announcement(text).post()
    }
}

extension View {
    /// Reads `text` aloud with VoiceOver each time it changes to a new non-empty value.
    func announcesChanges(_ text: String?) -> some View {
        onChange(of: text) { _, new in VoiceOverAnnouncer.post(new) }
    }
}
