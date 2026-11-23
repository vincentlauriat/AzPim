#if DEBUG
import AppKit
import SwiftUI

extension SnapshotRunner {
    /// Last refresh shown by the renders: today at 09:41, so screenshots do not carry the time they were taken.
    static var frozenRefresh: Date {
        Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now
    }

    /// Onboarding: the sign-in choice (Microsoft recommended) and the summary after an account was added.
    static func renderOnboarding(env: Env, directory: URL) {
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (name, page) in [("signin", OnboardingView(page: 1)), ("summary", OnboardingView(page: 2, added: (9, 3)))] {
                render(page, size: NSSize(width: 520, height: 420), scheme: scheme,
                       to: directory.appending(path: "onboarding-\(name)-\(suffix).png"), env: env)
            }
        }
    }
}
#endif
