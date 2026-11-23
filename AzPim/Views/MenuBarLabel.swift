import AzPimCore
import SwiftData
import SwiftUI

/// Menu bar label (DesignBrief › Components): `key.fill` when nothing is active; otherwise count + next expiry,
/// orange at ≤ 15 min, red at ≤ 5 min. An hourglass follows while a request waits for approval (an SF Symbol, so
/// the status item keeps it a template image). Rendered at launch: also opens Onboarding on first run.
struct MenuBarLabel: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query private var accountList: [Account]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" })
    private var pendingRecords: [ActivationRecord]

    /// Rows of the accounts in use, one per role (superseded Azure CLI rows count for nothing).
    private var model: PanelModel {
        let supersession = store.supersession(accountList)
        let accounts = accountList.filter { !supersession.isRetired($0.id) }
        return PanelModel(accounts: accounts, assignments: assignments, supersession: supersession, now: store.now)
    }

    var body: some View {
        let model = model
        label(activations: model.activations.map(\.assignment),
              badge: MenuBarBadge(activeCount: model.activations.count,
                                  pendingCount: model.pendingApprovalCount(in: pendingRecords)))
            .task {
                if !accounts.settings.onboardingCompleted {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    @ViewBuilder private func label(activations: [ActiveAssignment], badge: MenuBarBadge) -> some View {
        let style = accounts.settings.menuBarStyle
        let pending = badge.spokenPending.map { ", \($0)" } ?? ""
        if activations.isEmpty || style == .icon {
            HStack(spacing: 2) {
                Image(systemName: badge.keySymbol)
                if let symbol = badge.pendingSymbol { Image(systemName: symbol) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((activations.isEmpty ? String(localized: "AzPim, no active role")
                                 : String(localized: "AzPim, \(activations.count) active")) + pending)
        } else {
            let remaining = activations.compactMap(\.endAt).min().map { $0.timeIntervalSince(store.now) }
            HStack(spacing: 3) {
                Image(systemName: badge.keySymbol)
                Text(text(count: activations.count, remaining: style == .iconCountTime ? remaining : nil))
                    .monospacedDigit()
                if let symbol = badge.pendingSymbol { Image(systemName: symbol) }
            }
            .foregroundStyle(Countdown.color(remaining))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "AzPim, \(activations.count) active, next expiry in \(Countdown.spoken(remaining))")
                                + pending)
        }
    }

    private func text(count: Int, remaining: TimeInterval?) -> String {
        guard let remaining else { return "\(count)" }
        return "\(count) · \(Countdown.short(remaining))"
    }
}
