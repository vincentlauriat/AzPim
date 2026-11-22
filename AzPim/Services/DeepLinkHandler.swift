import AppKit
import AzPimCore

/// Handles `azpim://activate?favorite=<name>` (AppFlow › Deep links). SwiftUI routes `open` and `activate` URLs to
/// the main window (`handlesExternalEvents`), whose `onOpenURL` calls `handle`. An `NSApplicationDelegate`
/// `application(_:open:)` is not called under the SwiftUI lifecycle (verified 2026-11-04).
@MainActor
enum DeepLinkHandler {
    /// Set by `AzPimApp.init`, before any URL can arrive.
    static var store: RoleStore?
    /// Settings › Advanced: links may ask to activate favorites (default on). `role` and `open` links always work.
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
            NSApp.activate(ignoringOtherApps: true)
            // The name comes from the link: shown short and quoted, never as instructions.
            let shown = name.count > 40 ? String(name.prefix(40)) + "…" : name
            alert("No favorite named “\(shown)”.", info: "Create it in AzPim › Favorites.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Activate “\(favorite.name)”?"
        // Same policy as the run reads (fetched if never read), so the lines below match what is sent.
        for role in favorite.items.compactMap({ store.favoriteRole(for: $0) }) {
            await store.ensurePolicy(for: role)
        }
        // Everything the request will send: account, tenant, duration and justification of each role.
        let lines = favorite.items.compactMap { item -> String? in
            guard let role = store.favoriteRole(for: item) else { return nil }
            let account = role.account.map { "\($0.upn) (tenant \($0.tenantName ?? $0.tenantId))" } ?? "unknown account"
            // Same skip as the run: a request still waiting is not sent again.
            if store.waitingRequest(for: role) != nil {
                return "• \(role.roleName) — \(role.scopeName)\n   \(account): skipped (already requested, waiting)"
            }
            // Same computation as the run itself: what is shown is what will be sent (capped duration, fallback reason).
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification) {
            case .success(let input):
                let duration = ISODuration.label(ISODuration.seconds(input.duration) ?? 0)
                return "• \(role.roleName) — \(role.scopeName)\n   \(account), \(duration), “\(input.justification)”"
            case .failure(let failure):
                return "• \(role.roleName) — \(role.scopeName)\n   \(account): not sent (\(failure.userMessage))"
            }
        }
        confirm.informativeText = "A link asked AzPim to activate:\n" + lines.joined(separator: "\n")
        // Cancel is the default button: a Return typed for another app must not activate privileged roles.
        let activate = confirm.addButton(withTitle: "Activate")
        activate.keyEquivalent = ""
        let cancel = confirm.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let text = await store.run(favorite, fromPanel: false)
        alert(favorite.name, info: text)
    }

    private static func alert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
