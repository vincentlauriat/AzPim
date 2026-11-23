import AzPimCore
import SwiftUI
import UserNotifications

/// First use on iPhone: what AzPim does, the privacy promise, Sign in with Microsoft, and the admin-consent hint
/// (Entra roles and PIM groups need it once per tenant; Azure roles do not).
struct MobileOnboardingView: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 48)
                    .accessibilityHidden(true)
                Text("Welcome to AzPim").font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                Text("Activate, track and end your Microsoft PIM roles from your iPhone.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    Label("No server, no telemetry: your tokens never leave this iPhone except to Microsoft.",
                          systemImage: "lock.shield")
                    Label("Sign-in goes through Microsoft Authenticator when it is installed.",
                          systemImage: "person.badge.key")
                    Label("""
                        Entra roles and PIM groups need an administrator to consent once for your organization. \
                        Azure roles work without it.
                        """, systemImage: "checkmark.shield")
                }
                .font(.callout)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }

                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text("Sign in with Microsoft").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
                .controlSize(.large)
                .disabled(busy || !accounts.isMSALConfigured)

                if !accounts.isMSALConfigured {
                    Text("Microsoft sign-in is not configured in this build (no client ID).")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .announcesChanges(error)
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await accounts.addMSALAccount()
            if let settings = try? AzPimStore.settings(in: store.context) { settings.onboardingCompleted = true }
            // Expiry reminders with Extend: asked once, right after the first sign-in.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await store.refresh()
        } catch {
            self.error = AccountService.message(for: error)
        }
    }
}
