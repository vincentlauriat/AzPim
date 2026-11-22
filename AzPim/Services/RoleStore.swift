import AzPimCore
import Foundation
import SwiftData

/// Keeps the SwiftData cache in sync with Azure / Graph and runs activation requests (ImplementationPlan T3.3, T3.6, T3.7).
@MainActor
@Observable
final class RoleStore {
    let context: ModelContext
    let accounts: AccountService
    let notifications: NotificationScheduler
    private var autoRefresh: Task<Void, Never>?
    /// Bumped when the refresh loop is restarted (new interval): an older loop stops at its next wake-up.
    @ObservationIgnored private var autoRefreshGeneration = 0

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Errors of the last refresh, per account and source, as user messages.
    private(set) var refreshErrors: [UUID: [RoleSource: ErrorKind]] = [:]
    /// Last refresh that reached Microsoft (Offline state: "showing data from …").
    private(set) var lastOnline: Date?
    /// The network is unreachable: actions are disabled, cached data stays visible.
    var isOffline: Bool { refreshErrors.values.contains { $0.values.contains(.offline) } }
    /// Rows with a request in flight (local EligibleRole / ActiveAssignment id): a second request is refused.
    private var inFlight: Set<String> = []
    /// Rows shown busy: a request in flight, or an extension (including its waits between attempts).
    var busy: Set<String> { inFlight.union(extending) }
    /// Last error per row (local EligibleRole / ActiveAssignment id).
    var rowErrors: [String: String] = [:]
    /// When the panel was last opened (Activation timing).
    var panelOpenedAt: Date?
    /// Clock for countdowns: ticks every 30 s, every second in the last 5 minutes before an expiry (TRD › Performance).
    private(set) var now = Date.now
    private var clock: Task<Void, Never>?
    /// End date of the last expired activation that already triggered a refresh.
    @ObservationIgnored private var refreshedForExpiry: Date?
    /// Policy reads of the refresh that failed (unknown policy, network): retried after an hour, not on every refresh.
    /// The Activation Sheet and Extend read the policy directly and are not affected.
    @ObservationIgnored private var policyFailedAt: [String: Date] = [:]
    /// Requests waiting for an approver, per account (History Window), and the last error fetching them.
    var pending: [UUID: [RemoteRequest]] = [:]
    var pendingErrors: [UUID: String] = [:]
    /// Favorites being run, and the last result toast per favorite.
    var runningFavorites: Set<UUID> = []
    var favoriteToast: (favoriteId: UUID, text: String)?
    /// Last activation error per role, with whether it means "already active" (extend fallback).
    var lastActivationError: [String: (text: String, alreadyActive: Bool)] = [:]
    /// True while the History window is shown: pending requests are then listed on every refresh.
    var historyVisible = false
    /// Roles with an extension in flight (a second tap on another notification is refused), and the active row
    /// being extended.
    var extending: Set<String> = []
    private var refreshRequested = false
    /// The pending rerun was asked by the user, not by a timer (it may open a sign-in window).
    @ObservationIgnored private var userRefreshRequested = false
    /// Role to show in the Roles Window (notification tap, `azpim://role`); cleared once shown.
    var focusedRoleId: String?
    /// Account filter of the panel (nil = all accounts, T4.4).
    var accountFilter: UUID?
    #if DEBUG
    /// Snapshot fixtures: never refreshed (no `az`, no Keychain).
    @ObservationIgnored var snapshotFrozen = false
    #endif

    init(context: ModelContext, accounts: AccountService, notifications: NotificationScheduler) {
        self.context = context
        self.accounts = accounts
        self.notifications = notifications
    }

    // MARK: - Refresh

    /// Starts the refresh loop and the countdown clock (once, at launch).
    func start() {
        if autoRefresh == nil { startAutoRefresh() }
        guard clock == nil else { return }
        // Rows that expired before launch are handled by the launch refresh, not by a second one.
        refreshedForExpiry = expiredActivationEnd()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = .now
                let next = self.refreshAfterExpiry()
                let interval: Double = next.map { $0.timeIntervalSinceNow <= 300 ? 1 : 30 } ?? 30
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func startAutoRefresh(after delay: TimeInterval = 0) {
        autoRefreshGeneration += 1
        let generation = autoRefreshGeneration
        // The replaced loop is not cancelled: a cancellation would abort its refresh mid-request.
        autoRefresh = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled, self?.autoRefreshGeneration == generation {
                // Background: a token that needs the user surfaces as a banner, never as a sign-in window.
                await TokenInteraction.$isBackground.withValue(true) { await self?.refresh() }
                let minutes = self?.accounts.settings.refreshIntervalMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    /// Settings › Refresh interval: the new interval applies at once, counted from the last refresh.
    func restartAutoRefresh() {
        let interval = Double(accounts.settings.refreshIntervalMinutes * 60)
        let elapsed = lastRefresh.map { Date.now.timeIntervalSince($0) } ?? interval   // never refreshed: now
        startAutoRefresh(after: max(0, interval - elapsed))
    }

    /// Refresh when the panel opens and the data is older than 60 s (PRD open question 10).
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 { return }
        // Opening the panel must not pop a Microsoft sign-in window: the banner offers it.
        await TokenInteraction.$isBackground.withValue(true) { await refresh() }
    }

    /// A refresh asked while one runs is not dropped: it runs once more right after (an action's result must show).
    func refresh() async {
        #if DEBUG
        if snapshotFrozen { return }
        #endif
        guard !isRefreshing else {
            refreshRequested = true
            if !TokenInteraction.isBackground { userRefreshRequested = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var background = TokenInteraction.isBackground
        repeat {
            refreshRequested = false
            userRefreshRequested = false
            // A pass the user asked for (⌘R, Sign in, even queued behind a timer refresh) reads the Azure CLI again:
            // `az login` / `az logout` count now.
            if !background { await accounts.cliProvider.clearCache() }
            let list = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
            forgetRemovedAccounts(keeping: Set(list.map(\.id)))
            let superseded = AccountSupersede.superseded(list.map(\.facts))
            // A rerun asked by the user (Sign in, ⌘R) may open a sign-in window even if this run started in the background.
            await TokenInteraction.$isBackground.withValue(background) {
                for account in list {
                    if superseded[account.id] != nil {
                        self.retire(account)
                    } else {
                        await self.refresh(account)
                    }
                }
            }
            background = !userRefreshRequested
        } while refreshRequested
        if !isOffline { lastOnline = .now }
        lastRefresh = .now
        purgeHistory()
        await notifications.reschedule(activations: activeActivations(), leadMinutes: accounts.settings.notificationLeadMinutes)
        try? context.save()   // after reschedule: it records `notifiedAt`
    }

    private func refresh(_ account: Account) async {
        // Accounts that never had directory access offered: one silent try per launch, no window (decision 5).
        if account.mode == .msal, account.directoryAccess == .notRequested {
            await accounts.trySilentDirectoryAccess(for: account)
        }
        let service: PIMService
        do {
            service = PIMService(sources: try sources(for: account))
        } catch {
            refreshErrors[account.id] = [.azureResource: ErrorKind.classify(error)]
            return
        }
        let snapshot = await service.refresh()
        // Removed while its refresh was in flight: nothing to store.
        guard account.modelContext != nil, !account.isDeleted else { return }
        var errors: [RoleSource: ErrorKind] = [:]
        for (source, error) in snapshot.errors {
            if case TokenError.consentRequired = error {
                account.directoryAccess = .consentRequired
            } else {
                errors[source] = ErrorKind.classify(error)
            }
        }
        refreshErrors[account.id] = errors
        apply(snapshot, to: account, failedSources: Set(snapshot.errors.keys))
        account.lastRefreshAt = snapshot.fetchedAt
        await refreshPolicies(of: account, service: service)
        guard account.modelContext != nil, !account.isDeleted else { return }
        await refreshPending(of: account, service: service, failedSources: Set(snapshot.errors.keys))
    }

    /// Policies are cached 24 h (BackendSchema › EligibleRole.policyFetchedAt).
    private func refreshPolicies(of account: Account, service: PIMService) async {
        for role in account.eligibleRoles {
            if let fetched = role.policyFetchedAt, Date.now.timeIntervalSince(fetched) < 86_400 { continue }
            if let failed = policyFailedAt[role.id], Date.now.timeIntervalSince(failed) < 3600 { continue }
            guard let source = service.source(for: role.source) else { continue }
            if let policy = try? await source.policy(for: role.remote) {
                role.policy = policy
                policyFailedAt[role.id] = nil
            } else {
                policyFailedAt[role.id] = .now
            }
        }
    }

    // MARK: - Actions

    /// Sends an activation request; returns the outcome status, or nil on failure (error stored per row).
    /// `fromPanel` false for deep links and notification actions: no `panelOpenedAt`, so the record stays out of
    /// the time-to-activation median. `refreshAfter` false when the caller refreshes once after a batch.
    /// `discardIfAlreadyActive` true for an attempt the caller will retry when Azure still reports the role as
    /// active: that refusal is removed instead of staying in History as a failure.
    @discardableResult
    func activate(_ role: EligibleRole, input: ActivationInput, viaFavorite: String? = nil, fromPanel: Bool = true,
                  action: ActivationAction = .activate, refreshAfter: Bool = true,
                  discardIfAlreadyActive: Bool = false) async -> RequestStatus? {
        guard let account = role.account else { return nil }
        // One request per row: a second tap, a second sheet or a favorite during an Extend must not submit it twice.
        guard action == .extend || !extending.contains(role.id), inFlight.insert(role.id).inserted else {
            rowErrors[role.id] = "A request for this role is already in progress."
            lastActivationError[role.id] = nil
            return nil
        }
        defer { inFlight.remove(role.id) }
        rowErrors[role.id] = nil
        lastActivationError[role.id] = nil
        let record = ActivationRecord(account: account, eligibleRoleId: role.id, roleName: role.roleName,
                                      scopeName: role.scopeName, source: role.source, action: action,
                                      requestedDuration: input.duration, justification: input.justification,
                                      ticketNumber: input.ticketNumber, panelOpenedAt: fromPanel ? recentPanelOpen : nil,
                                      viaFavorite: viaFavorite)
        context.insert(record)
        do {
            guard let source = try PIMService(sources: sources(for: account)).source(for: role.source) else {
                throw TokenError.consentRequired
            }
            let outcome = try await source.activate(role.remote, principalId: account.objectId, input: input)
            record.remoteRequestId = outcome.requestId
            // Azure answered but did not apply the request: a failure, shown on the row (the role can be activated again).
            if [.failed, .denied, .canceled].contains(outcome.status) { throw RequestRefused(status: outcome.status) }
            record.status = outcome.status
            rowErrors[role.id] = nil   // a refused duplicate meanwhile left its message
            if outcome.status == .provisioned { record.completedAt = .now }
            role.lastJustification = input.justification
            try? context.save()
            if refreshAfter { await refresh() }
            return outcome.status
        } catch {
            let alreadyActive = ExtendPlan.isAlreadyActive(error)
            lastActivationError[role.id] = (Self.message(for: error), alreadyActive)
            if discardIfAlreadyActive && alreadyActive {
                context.delete(record)
            } else {
                record.status = (error as? RequestRefused)?.status ?? .failed
                record.errorMessage = Self.message(for: error)
                rowErrors[role.id] = record.errorMessage
            }
            try? context.save()
            return nil
        }
    }

    @discardableResult
    func deactivate(_ assignment: ActiveAssignment, refreshAfter: Bool = true) async -> Bool {
        guard let account = assignment.account, let role = assignment.eligibleRole else {
            rowErrors[assignment.id] = "This assignment is permanent and cannot be deactivated."
            return false
        }
        // The row may be deleted by a refresh while the request runs: use copies after the first `await`.
        let rowId = assignment.id
        guard inFlight.insert(rowId).inserted else { return false }
        defer { inFlight.remove(rowId) }
        rowErrors[rowId] = nil
        let record = ActivationRecord(account: account, eligibleRoleId: role.id, roleName: role.roleName,
                                      scopeName: role.scopeName, source: role.source, action: .deactivate)
        context.insert(record)
        do {
            guard let source = try PIMService(sources: sources(for: account)).source(for: role.source) else {
                throw TokenError.consentRequired
            }
            let outcome = try await source.deactivate(role.remote, principalId: account.objectId)
            record.remoteRequestId = outcome.requestId
            record.status = outcome.status == .failed ? .failed : .provisioned
            record.completedAt = .now
            if record.status == .failed {
                record.errorMessage = RequestRefused(status: .failed).errorDescription
                rowErrors[rowId] = record.errorMessage
            }
            try? context.save()
            if refreshAfter { await refresh() }
            return record.status == .provisioned
        } catch {
            record.status = .failed
            record.errorMessage = Self.message(for: error)
            rowErrors[rowId] = record.errorMessage
            try? context.save()
            return false
        }
    }

    // MARK: - Queries

    /// Panel open time if recent: a stale value (panel `onAppear` not called again) would inflate the median.
    private var recentPanelOpen: Date? {
        guard let opened = panelOpenedAt, Date.now.timeIntervalSince(opened) < 600 else { return nil }
        return opened
    }

    static func message(for error: Error) -> String {
        ErrorKind.classify(error).message
    }

}

// MARK: - Expiry

extension RoleStore {
    /// Refreshes once when a cached activation has just expired, so the panel, the favorites and Extend
    /// stop relying on it (Azure is the source of truth). Returns the next expiry still to come (one fetch per tick).
    fileprivate func refreshAfterExpiry() -> Date? {
        let activated = ((try? context.fetch(FetchDescriptor<ActiveAssignment>())) ?? []).filter { $0.assignmentType == .activated }
        let now = Date.now
        let expired = activated.compactMap(\.endAt).filter { $0 <= now }.max()
        if let expired, expired != refreshedForExpiry {
            refreshedForExpiry = expired
            Task { await TokenInteraction.$isBackground.withValue(true) { await self.refresh() } }
        }
        return activated.compactMap(\.endAt).filter { $0 > now }.min()
    }

    fileprivate func expiredActivationEnd() -> Date? {
        let all = (try? context.fetch(FetchDescriptor<ActiveAssignment>())) ?? []
        return all.filter { $0.assignmentType == .activated }.compactMap(\.endAt).filter { $0 <= .now }.max()
    }
}

// MARK: - Cache

extension RoleStore {
    /// Per-account state of accounts removed since (an old Offline entry would keep actions disabled).
    func forgetRemovedAccounts(keeping ids: Set<UUID>) {
        for id in refreshErrors.keys where !ids.contains(id) { refreshErrors[id] = nil }
        for id in pending.keys where !ids.contains(id) { pending[id] = nil }
        for id in pendingErrors.keys where !ids.contains(id) { pendingErrors[id] = nil }
        if let filter = accountFilter, !ids.contains(filter) { accountFilter = nil }
    }

    /// A superseded account is not refreshed: its cached assignments go (they would count, notify and show twice) and
    /// its errors and pending requests are forgotten (a stale Offline would disable every action). Its eligible roles
    /// stay, hidden, so favorites made on it resolve and the account works again at once if the MSAL one is removed.
    fileprivate func retire(_ account: Account) {
        refreshErrors[account.id] = nil
        pending[account.id] = nil
        pendingErrors[account.id] = nil
        if accountFilter == account.id { accountFilter = nil }
        for assignment in account.activeAssignments {
            context.delete(assignment)
        }
    }
}
