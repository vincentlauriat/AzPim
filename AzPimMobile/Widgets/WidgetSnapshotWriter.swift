import Foundation
import UIKit
import WidgetKit

/// Writes the widgets' snapshot (`RoleStore.widgetSnapshot`) to the App Group container after every store refresh
/// (activation, Extend, deactivation, expiry and timer refreshes all end with one), when the app comes to the
/// foreground and when it leaves it (a favorite edited meanwhile). The widgets are reloaded only when the roles or the
/// favorites changed: a reload spends the system's widget budget.
@MainActor
final class WidgetSnapshotWriter {
    private let store: RoleStore
    private let url: URL?
    private var written: WidgetSnapshot?
    private var observers: [NSObjectProtocol] = []

    #if DEBUG
    /// Demo mode: only `AZPIM_DEMO=widgets` writes, the other screens leave the widgets' file alone.
    var demoAllowed = true
    #endif

    init(store: RoleStore, url: URL? = WidgetSnapshot.fileURL) {
        self.store = store
        self.url = url
        written = WidgetSnapshot.read(from: url)
        followRefreshes()
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.write() }
            })
        }
    }

    /// Every refresh sets `lastRefresh` once its activations are stored; the write runs right after.
    private func followRefreshes() {
        withObservationTracking { _ = store.lastRefresh } onChange: { [weak self] in
            Task { @MainActor in
                self?.write()
                self?.followRefreshes()
            }
        }
    }

    /// Writes the snapshot when its content changed, atomically, then reloads the widgets. Before the first refresh
    /// the store holds the last session's cache: written as well, the widgets show it until the refresh lands.
    func write() {
        #if DEBUG
        guard demoAllowed else { return }
        #endif
        guard let url else { return }   // no App Group (unsigned build): no widget can read it either
        let snapshot = store.widgetSnapshot()
        guard !snapshot.hasSameContent(as: written) else { return }
        do {
            try snapshot.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return   // the widgets keep the previous snapshot; the next refresh tries again
        }
        written = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }
}
