#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AzPimCore
import SwiftUI

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
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    #else
                    UIPasteboard.general.string = command
                    #endif
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
