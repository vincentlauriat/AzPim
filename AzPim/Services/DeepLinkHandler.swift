import AppKit
import AzPimCore

/// Handles `azpim://activate?favorite=<name>` (AppFlow › Deep links). SwiftUI routes `open` and `activate` URLs to
/// the main window (`handlesExternalEvents`), whose `onOpenURL` calls `handle`. An `NSApplicationDelegate`
/// `application(_:open:)` is not called under the SwiftUI lifecycle (verified 2026-11-04).
@MainActor
enum DeepLinkHandler {
    /// Set by `AzPimApp.init`, before any URL can arrive.
    static var store: RoleStore?
    /// Settings › Accounts › Advanced: links may ask to run favorites, and Shortcuts actions to activate roles and
    /// favorites (default on; `RoleStore.intentActivationAllowed`). `role` and `open` links, and Shortcuts' Deactivate
    /// All, always work.
    static let activationKey = PreferenceKeys.allowLinkActivation
    /// A confirmation is on screen: further activation links are ignored, not queued (no prompt flood).
    private static var confirming = false

    static func handle(_ url: URL) {
        guard url.scheme == "azpim" else { return }
        switch url.host() {
        case "activate":
            guard UserDefaults.standard.object(forKey: activationKey) as? Bool ?? true, !confirming else { return }
            let name = DeepLink.value(of: "favorite", in: url) ?? ""
            Task { await runFavorite(named: name) }
        case "open":
            NSApp.activate(ignoringOtherApps: true)
        case "role":
            // Shows a role (read-only navigation, nothing is activated).
            let id = DeepLink.value(of: "id", in: url)
            NSApp.activate(ignoringOtherApps: true)
            // A role of a superseded Azure CLI account is shown as the Microsoft sign-in's same role.
            if let id, !id.isEmpty, let role = store?.resolvedRole(id: id) { store?.focusedRoleId = role.id }
        default:
            break
        }
    }

    /// `azpim://role?id=<eligible role id>`, or nil without an id.
    static func roleURL(_ roleId: String?) -> URL? {
        roleId.flatMap(DeepLink.role(id:))
    }

    /// Any local process can open a URL: activating privileged roles always asks the user first.
    private static func runFavorite(named name: String) async {
        guard let store = Self.store, !confirming else { return }
        confirming = true
        defer { confirming = false }
        guard let favorite = store.favorite(named: name) else {
            // The name comes from the link: shown short and quoted, never as instructions. Nothing to decide: a
            // notification (or the panel's status), not a modal.
            let shown = name.count > 40 ? String(name.prefix(40)) + "…" : name
            await store.announce(title: String(localized: "No favorite named “\(shown)”."),
                                 body: String(localized: "Create it in AzPim › Favorites."))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = String(localized: "Activate “\(favorite.name)”?")
        // Same policy as the run reads (fetched if never read), so the lines below match what is sent.
        for role in favorite.items.compactMap({ store.favoriteRole(for: $0) }) {
            await store.ensurePolicy(for: role)
        }
        // Everything the request will send: account, tenant, duration and justification of each role.
        let lines = favorite.items.compactMap { item -> String? in
            guard let role = store.favoriteRole(for: item) else { return nil }
            let account = role.account.map { String(localized: "\($0.upn) (tenant \($0.tenantName ?? $0.tenantId))") }
                ?? String(localized: "unknown account")
            let heading = "• \(role.displayRoleName) — \(role.displayScopeName)\n   "
            // Same skip as the run: a request still waiting is not sent again.
            if store.waitingRequest(for: role) != nil {
                return heading + String(localized: "\(account): skipped (already requested, waiting)")
            }
            // Same skip as the run (`requireKnownPolicy`): never sent on a policy's defaults.
            if role.policyFetchedAt == nil {
                return heading + String(localized: "\(account): not sent (\(String(localized: "unreadable policy")))")
            }
            // Same computation as the run itself: what is shown is what will be sent (capped duration, fallback reason).
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification) {
            case .success(let input):
                let duration = ISODuration.label(ISODuration.seconds(input.duration) ?? 0)
                return heading + "\(account), \(duration), “\(input.justification)”"
            case .failure(let failure):
                return heading + String(localized: "\(account): not sent (\(failure.userMessage))")
            }
        }
        confirm.informativeText = String(localized: "A link asked AzPim to activate:") + "\n" + lines.joined(separator: "\n")
        // Cancel is the default button: a Return typed for another app must not activate privileged roles.
        let activate = confirm.addButton(withTitle: String(localized: "Activate"))
        activate.keyEquivalent = ""
        let cancel = confirm.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\r"
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        // The policies the lines above were built from: never read again (nor sent on defaults) by the run.
        // The result is notified (or shown in the panel when notifications are off), never a modal.
        await store.run(favorite, fromPanel: false, requireKnownPolicy: true, announce: true)
    }
}
