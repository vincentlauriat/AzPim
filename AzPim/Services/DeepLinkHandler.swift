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
        // After a cold launch by the link: the launch refresh first, so the lines leave out superseded accounts.
        do {
            try await store.intentReady()
        } catch {
            // Still loading after about a minute: nothing is asked or sent on unfiltered data.
            NSApp.activate(ignoringOtherApps: true)
            alert(String(localized: "Couldn't run the link."),
                  info: (error as? RoleStore.IntentFailure)?.message ?? RoleStore.message(for: error))
            return
        }
        guard let favorite = store.favorite(named: name) else {
            NSApp.activate(ignoringOtherApps: true)
            // The name comes from the link: shown short and quoted, never as instructions. A dialog, not a
            // notification: any local process can open links, and must not post notifications through AzPim.
            let shown = name.count > 40 ? String(name.prefix(40)) + "…" : name
            alert(String(localized: "No favorite named “\(shown)”."), info: String(localized: "Create it in AzPim › Favorites."))
            return
        }
        // Everything the request will send: account, tenant, duration and justification of each role; the run sends
        // only the roles listed as sent, on the policies the lines were built from.
        let outcome = await store.linkRunFavorite(favorite) { text in
            NSApp.activate(ignoringOtherApps: true)
            let confirm = NSAlert()
            confirm.messageText = String(localized: "Activate “\(favorite.name)”?")
            confirm.informativeText = text
            // Cancel is the default button: a Return typed for another app must not activate privileged roles.
            let activate = confirm.addButton(withTitle: String(localized: "Activate"))
            activate.keyEquivalent = ""
            let cancel = confirm.addButton(withTitle: String(localized: "Cancel"))
            cancel.keyEquivalent = "\r"
            confirm.alertStyle = .warning
            return confirm.runModal() == .alertFirstButtonReturn
        }
        guard let outcome else { return }
        // A full success is notified (or shown as the favorite's toast when notifications are off). Anything else
        // (a role failed, sign-in or consent needed, already running) is never silent: a dialog with the details.
        if outcome.isFullSuccess {
            await store.announce(favorite: favorite.name, outcome)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert(favorite.name, info: outcome.text)
        }
    }

    private static func alert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
