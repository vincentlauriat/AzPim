import Foundation

extension MobileNavigation {
    /// `azpim://role?id=<eligible role id>` (the Live Activity's Extend): opens the role's detail, whose Extend runs in
    /// the foreground, as the expiry notification's Extend does (`NotificationScheduler.extendOpensApp`): run from the
    /// lock screen in the background, an Extend suspended between its deactivation and its re-activation would leave the
    /// role deactivated. The link never extends by itself, since any app can open it: the detail waits for Extend.
    func openRole(_ url: URL, store: RoleStore) {
        guard let id = WidgetSnapshot.roleID(in: url) else { return }
        let before = selection
        Task {
            // After a cold launch by the link: the launch refresh first, so the role is loaded when it is focused.
            guard (try? await store.intentReady()) != nil else { return }
            // The user chose another role while the refresh ran: theirs wins.
            guard selection == before else { return }
            // The role must be in view, not pushed under a sheet or the Deactivate question.
            dismissPresented()
            store.focusedRoleId = id
        }
    }
}
