import AzPimCore
import Foundation

extension ExtendRoleActivityIntent {
    /// App side of the Live Activity's Extend: the store's Extend, the same path as Extend in the app and in the
    /// expiry notification (`RoleStore.runExtend`). Never interactive: a token that needs the user fails instead of
    /// opening a sign-in the lock screen cannot show. The result is posted as a notification (when allowed), with the
    /// notification wording that never carries an Azure error detail (the role's row in the app shows it); the refresh
    /// that ends the Extend updates the activity.
    @MainActor
    static func register(store: RoleStore) {
        handler = { [weak store] roleId in
            guard let store else { throw NotReady() }
            do {
                try await store.intentReady()
            } catch let failure as RoleStore.IntentFailure {
                throw Failure(message: failure.message)
            }
            let title = store.resolvedRole(id: roleId).map { "\($0.displayRoleName) — \($0.displayScopeName)" }
                ?? String(localized: "Extend")
            let text = await TokenInteraction.$isBackground.withValue(true) {
                await store.extendFromNotification(eligibleRoleId: roleId)
            }
            await store.notifications.notifyResult(title: title, body: text, roleId: roleId)
        }
    }

    /// A store message, already localized.
    struct Failure: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
        let message: String
        var localizedStringResource: LocalizedStringResource { LocalizedStringResource("\(message)") }
        var errorDescription: String? { message }
    }
}
