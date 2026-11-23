#if DEBUG
import AppKit
import AzPimCore
import SwiftData
import SwiftUI

extension SnapshotRunner {
    /// Increase Contrast (the Theme tokens' high-contrast versions, forced by `contrastOverride`): the panel and the
    /// ticket Activation Sheet, after the other renders (the request waiting for approval shows in the panel).
    static func renderContrast(env: Env, directory: URL, defaults: UserDefaults) {
        Theme.contrastOverride = true
        defer { Theme.contrastOverride = nil }
        let ticket = ((try? env.container.mainContext.fetch(FetchDescriptor<EligibleRole>())) ?? [])
            .first { $0.id.hasSuffix("|e-secreader") && $0.account?.mode == .msal }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            defaults.removePersistentDomain(forName: suiteName)
            render(MenuBarPanel(),
                   size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                   to: directory.appending(path: "panel-contrast-\(suffix).png"), env: env)
            if let ticket {
                render(ActivationSheet(role: ticket) {},
                       size: NSSize(width: Theme.panelWidth, height: 1400), scheme: scheme,
                       to: directory.appending(path: "sheet-ticket-contrast-\(suffix).png"), env: env)
            }
        }
    }
}
#endif
