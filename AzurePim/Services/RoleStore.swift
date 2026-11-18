import AzurePimCore
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

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Errors of the last refresh, per account and source, as user messages.
    private(set) var refreshErrors: [UUID: [RoleSource: ErrorKind]] = [:]
    /// Last refresh that reached Microsoft (Offline state: "showing data from …").
    private(set) var lastOnline: Date?
    /// The network is unreachable: actions are disabled, cached data stays visible.
    var isOffline: Bool { refreshErrors.values.contains { $0.values.contains(.offline) } }
    /// Rows with a request in flight, and the last error per row (local EligibleRole / ActiveAssignment id).
    private(set) var busy: Set<String> = []
    var rowErrors: [String: String] = [:]
    /// When the panel was last opened (Activation timing).
    var panelOpenedAt: Date?
    /// Clock for countdowns: ticks every 30 s, every second in the last 5 minutes before an expiry (TRD › Performance).
    private(set) var now = Date.now
    private var clock: Task<Void, Never>?
    /// End date of the last expired activation that already triggered a refresh.
    @ObservationIgnored private var refreshedForExpiry: Date?
    /// Background policy reads that failed (unknown policy, network): retried after an hour, not on every refresh.
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
    /// Roles with an extension in flight (a second tap on another notification is refused).
    var extending: Set<String> = []
    private var refreshRequested = false
    /// The pending rerun was asked by the user, not by a timer (it may open a sign-in window).
    @ObservationIgnored private var userRefreshRequested = false
    /// Account filter of the panel (nil = all accounts, T4.4).
    var accountFilter: UUID?

    init(context: ModelContext, accounts: AccountService, notifications: NotificationScheduler) {
        self.context = context
        self.accounts = accounts
        self.notifications = notifications
    }

    // MARK: - Refresh

    /// Starts the refresh loop and the countdown clock (once, at launch).
    func start() {
        startAutoRefresh()
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

    private func startAutoRefresh() {
        guard autoRefresh == nil else { return }
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                // Background: a token that needs the user surfaces as a banner, never as a sign-in window.
                await TokenInteraction.$isBackground.withValue(true) { await self?.refresh() }
                let minutes = self?.accounts.settings.refreshIntervalMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    /// Refresh when the panel opens and the data is older than 60 s (PRD open question 10).
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 { return }
        // Opening the panel must not pop a Microsoft sign-in window: the banner offers it.
        await TokenInteraction.$isBackground.withValue(true) { await refresh() }
    }

    /// A refresh asked while one runs is not dropped: it runs once more right after (an action's result must show).
    func refresh() async {
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
            let list = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
            // A rerun asked by the user (Sign in, ⌘R) may open a sign-in window even if this run started in the background.
            await TokenInteraction.$isBackground.withValue(background) {
                for account in list {
                    await self.refresh(account)
                }
            }
            background = !userRefreshRequested
        } while refreshRequested
        if !isOffline { lastOnline = .now }
        lastRefresh = .now
        purgeHistory()
        try? context.save()
        await notifications.reschedule(activations: activeActivations(), leadMinutes: accounts.settings.notificationLeadMinutes)
    }

    private func refresh(_ account: Account) async {
        let service: PIMService
        do {
            service = PIMService(sources: try sources(for: account))
        } catch {
            refreshErrors[account.id] = [.azureResource: ErrorKind.classify(error)]
            return
        }
        let snapshot = await service.refresh()
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
        await refreshPending(of: account, service: service, failedSources: Set(snapshot.errors.keys))
    }

    /// Replaces the cache of one account. Sources that failed keep their previous rows (offline / throttled).
    private func apply(_ snapshot: AccountSnapshot, to account: Account, failedSources: Set<RoleSource>) {
        var existing = Dictionary(uniqueKeysWithValues: account.eligibleRoles.map { ($0.remoteId, $0) })
        var kept: [String: EligibleRole] = [:]
        for remote in snapshot.eligibilities {
            let role = existing.removeValue(forKey: remote.id)
                ?? EligibleRole(id: remote.id, account: account, source: remote.source, roleDefinitionId: remote.roleDefinitionId,
                                roleName: remote.roleName, scope: remote.scope, scopeName: remote.scopeName,
                                scopeType: remote.scopeType, memberType: remote.memberType)
            if role.modelContext == nil { context.insert(role) }
            role.roleName = remote.roleName
            role.scopeName = remote.scopeName
            role.fetchedAt = snapshot.fetchedAt
            kept[remote.matchKey] = role
        }
        for stale in existing.values where !failedSources.contains(stale.source) {
            context.delete(stale)
        }

        for old in account.activeAssignments where !failedSources.contains(old.source) {
            context.delete(old)
        }
        for remote in snapshot.assignments {
            let eligible = snapshot.eligibility(for: remote).flatMap { kept[$0.matchKey] }
            let assignment = ActiveAssignment(id: remote.id, account: account, source: remote.source, roleName: remote.roleName,
                                              scope: remote.scope, scopeName: remote.scopeName, assignmentType: remote.type,
                                              startAt: remote.startAt, endAt: remote.endAt, eligibleRole: eligible)
            context.insert(assignment)
        }
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

    func sources(for account: Account) throws -> [any PIMSource] {
        let provider = try accounts.provider(for: account)
        let tenantId = account.tenantId, objectId = account.objectId.lowercased(), upn = account.upn
        return PIMService.sources(token: { resource, claims in
            let token = try await provider.token(for: resource, tenantId: tenantId, claims: claims)
            // `az` follows whoever last ran `az login`: never act for one account with another identity's token.
            if let oid = JWTClaims(token: token.value)?.objectId, oid.lowercased() != objectId {
                throw TokenError.cliNotSignedIn(command: "az login  # as \(upn)")
            }
            return token
        }, directory: account.directoryAccess == .enabled)
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
        busy.insert(role.id)
        rowErrors[role.id] = nil
        lastActivationError[role.id] = nil
        defer { busy.remove(role.id) }
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
            record.status = outcome.status
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
                record.status = .failed
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
        busy.insert(assignment.id)
        rowErrors[assignment.id] = nil
        defer { busy.remove(assignment.id) }
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
            try? context.save()
            if refreshAfter { await refresh() }
            return record.status == .provisioned
        } catch {
            record.status = .failed
            record.errorMessage = Self.message(for: error)
            rowErrors[assignment.id] = record.errorMessage
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

    func activeActivations() -> [ActiveAssignment] {
        let all = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        return all.filter { $0.assignmentType == .activated && $0.isLive() }
    }

    static func message(for error: Error) -> String {
        ErrorKind.classify(error).message
    }
}

// MARK: - Policies

extension RoleStore {
    /// Fetches the policy now if it was never read (Activation Sheet needs it before validating).
    func ensurePolicy(for role: EligibleRole) async {
        guard role.policyFetchedAt == nil, let account = role.account,
              let source = try? PIMService(sources: sources(for: account)).source(for: role.source),
              let policy = try? await source.policy(for: role.remote) else { return }
        role.policy = policy
        try? context.save()
    }

    /// Reads the policy from Azure / Graph now, ignoring the 24 h cache. False if it could not be read.
    func refreshPolicy(for role: EligibleRole) async -> Bool {
        guard let account = role.account,
              let source = try? PIMService(sources: sources(for: account)).source(for: role.source),
              let policy = try? await source.policy(for: role.remote) else { return false }
        role.policy = policy
        try? context.save()
        return true
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
