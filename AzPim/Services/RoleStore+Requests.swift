import AzPimCore
import Foundation
import SwiftData

/// Extend, favorites and pending requests (ImplementationPlan T4.1–T4.3).
extension RoleStore {
    // MARK: - Extend (T4.1)

    /// Extends an activation (see `ExtendPlan`): Azure keeps one activation per eligibility, so the current one is
    /// ended and the role activated again with its last parameters. Returns the text of the follow-up notification,
    /// which always says whether the role is still held.
    func extend(eligibleRoleId: String) async -> String {
        guard !extending.contains(eligibleRoleId) else { return String(localized: "An extension is already running for this role.") }
        extending.insert(eligibleRoleId)
        defer { extending.remove(eligibleRoleId) }
        guard let role = eligibleRole(id: eligibleRoleId) else { return String(localized: "This role is no longer eligible.") }
        guard let current = activeActivations().first(where: { $0.eligibleRole?.id == eligibleRoleId }) else {
            return String(localized: "\(role.displayRoleName) is no longer active.")
        }
        // The active row stays busy too (`isBusy`), through the policy read, the deactivation and the waits between
        // attempts, even when a refresh replaces it meanwhile.
        let activeSince = current.startAt
        let lastDuration = role.account?.records
            .filter { $0.eligibleRoleId == eligibleRoleId && $0.action != .deactivate && $0.requestedDuration != nil }
            .max { $0.sentAt < $1.sentAt }?.requestedDuration
            // Records stay under the account that sent them: after the Microsoft sign-in superseded the Azure CLI
            // account, the duration remembered for the role is used; else `ExtendPlan` falls back to 1 h.
            ?? self.lastDuration(for: role)
        // Never decide on a cached or default policy: ending the activation must be safe to undo.
        guard await refreshPolicy(for: role) else {
            return String(localized: "Couldn't read the role's policy: not extended, the role is still active.")
        }
        switch ExtendPlan.decide(policy: role.policy, lastJustification: role.lastJustification, lastDuration: lastDuration,
                                 activeSince: activeSince) {
        case .blocked(let reason):
            return String(localized: "\(reason) The role is still active.")
        case .reactivate(let input):
            return await reactivate(role, input: input)
        }
    }

    /// An active row is busy while its own request runs, or while its role is extended: keyed on the eligible role,
    /// not on the row, so the row a refresh puts in its place during the extension (new instance id) is busy too.
    func isBusy(_ assignment: ActiveAssignment) -> Bool {
        busy.contains(assignment.id) || assignment.eligibleRole.map { extending.contains($0.id) } == true
    }

    private func reactivate(_ role: EligibleRole, input: ActivationInput) async -> String {
        let roleId = role.id
        guard let current = activeActivations().first(where: { $0.eligibleRole?.id == roleId }) else {
            return String(localized: "\(role.displayRoleName) is no longer active.")
        }
        let currentId = current.id
        guard await deactivate(current, refreshAfter: false) else {
            let detail = rowErrors[currentId] ?? String(localized: "deactivation failed")
            return String(localized: "Couldn't extend: \(detail). The role is still active.")
        }
        // Azure may still report the old activation for a few seconds after the deactivation. Refusals that are
        // retried leave no record: History shows one extension, plus the last refusal if every attempt failed.
        var status: RequestStatus?
        let delays = [0, 3, 6, 12]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try? await sleep(.seconds(delay)) }
            status = await activate(role, input: input, fromPanel: false, action: .extend, refreshAfter: false,
                                    discardIfAlreadyActive: attempt < delays.count - 1)
            if status != nil || lastActivationError[roleId]?.alreadyActive != true { break }
        }
        await refresh()
        switch status {
        case .provisioned?:
            let end = Date.now.addingTimeInterval(ISODuration.seconds(input.duration) ?? 0)
            return String(localized: "Extended until \(end.appFormatted(date: .omitted, time: .shortened)).")
        case .pendingApproval?:
            return String(localized: "Role deactivated; the new activation is waiting for approval.")
        case .sent?:
            return String(localized: "Role deactivated; the new activation was sent but not confirmed yet. Check the panel in a moment.")
        default:
            let detail = rowErrors[roleId] ?? String(localized: "unknown error")
            return String(localized: "Role deactivated; re-activation failed: \(detail). Activate it from the panel.")
        }
    }

    /// A request Microsoft answered with Failed, Denied or Canceled: nothing was activated.
    struct RequestRefused: LocalizedError {
        let status: RequestStatus
        var errorDescription: String? {
            String(localized: "Microsoft answered “\(status.rawValue)”: the request was not applied. Check the role in the Azure portal.")
        }
    }

    /// Panel open time if recent: a stale value (panel `onAppear` not called again) would inflate the median.
    var recentPanelOpen: Date? {
        guard let opened = panelOpenedAt, Date.now.timeIntervalSince(opened) < 600 else { return nil }
        return opened
    }

    static func message(for error: Error) -> String {
        ErrorKind.classify(error).message
    }

    func eligibleRole(id: String) -> EligibleRole? {
        var descriptor = FetchDescriptor<EligibleRole>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Favorites (T4.2)

    /// Activates every role of a favorite without a sheet. Returns the toast text. `answers`: what the grouped favorite
    /// sheet asked (`favoriteNeeds`); without them a role that requires a ticket is not sent. `requireKnownPolicy`
    /// (links, Shortcuts): the policy is never read here, and a role whose policy was never read is not sent. `only`:
    /// the eligible role ids a confirmation listed as sent; any other role is not sent.
    @discardableResult
    func run(_ favorite: Favorite, fromPanel: Bool = true, answers: FavoriteAnswers? = nil,
             requireKnownPolicy: Bool = false, only: Set<String>? = nil) async -> String {
        // Value copies: the model may be deleted while requests are in flight.
        let favoriteId = favorite.id, favoriteName = favorite.name, items = favorite.items
        guard !runningFavorites.contains(favoriteId) else { return String(localized: "\(favoriteName) is already running.") }
        runningFavorites.insert(favoriteId)
        defer { runningFavorites.remove(favoriteId) }
        let active = Set(activeActivations().compactMap { $0.eligibleRole?.id })
        var results: [FavoriteRoleResult] = []
        for item in items {
            // Roles saved under an Azure CLI account now replaced by a Microsoft sign-in run under the latter.
            guard let role = favoriteRole(for: item) else {
                results.append(.init(roleName: String(localized: "Unknown role"), status: nil,
                                     error: String(localized: "no longer eligible")))
                continue
            }
            if active.contains(role.id) {
                results.append(.init(roleName: role.displayRoleName, status: .provisioned))
                continue
            }
            // A request still waiting (approval, or sent and not confirmed) is not submitted a second time.
            if let waiting = waitingRequest(for: role) {
                results.append(.init(roleName: role.displayRoleName, status: waiting.status))
                continue
            }
            if !requireKnownPolicy { await ensurePolicy(for: role) }
            // Links and Shortcuts send only what their confirmation showed: never on a policy's defaults, never a role
            // whose policy was read only after it.
            let refusal = requireKnownPolicy && role.policyFetchedAt == nil ? String(localized: "unreadable policy")
                : only.map { $0.contains(role.id) } == false ? String(localized: "not confirmed") : nil
            if let refusal {
                results.append(.init(roleName: role.displayRoleName, status: nil, error: refusal))
                continue
            }
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification,
                                     answers: answers, tenantId: role.account?.tenantId ?? "") {
            case .failure(let failure):
                results.append(.init(roleName: role.displayRoleName, status: nil, error: failure.userMessage))
            case .success(let input):
                let status = await activate(role, input: input, viaFavorite: favoriteName, fromPanel: fromPanel,
                                            refreshAfter: false)
                results.append(.init(roleName: role.displayRoleName, status: status, error: rowErrors[role.id]))
            }
        }
        await refresh()
        let text = FavoriteRun.summary(results)
        favoriteToast = (favoriteId, text)
        return text
    }

    /// The request of this role still waiting for its outcome, if any (`ActivationRecord.isWaiting`), including one
    /// sent for the same eligibility through an Azure CLI account the role's account has since superseded.
    /// Only undecided records are fetched (the sheet asks on every clock tick). `now`: the store clock in views, so a
    /// sent request stops blocking once its 15-minute window is over.
    func waitingRequest(for role: EligibleRole, at now: Date = .now) -> ActivationRecord? {
        let supersession = supersession()
        let pending = RequestStatus.pendingApproval.rawValue, sent = RequestStatus.sent.rawValue
        let descriptor = FetchDescriptor<ActivationRecord>(predicate: #Predicate {
            $0.statusRaw == pending || $0.statusRaw == sent
        })
        let records = (try? context.fetch(descriptor)) ?? []
        return records.first {
            $0.isWaiting(at: now) && supersession.resolve(eligibleRoleId: $0.eligibleRoleId, source: $0.source) == role.id
        }
    }

    func favorite(named name: String) -> Favorite? {
        let all = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        return all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - History (T4.3)

    /// Cancels a pending request (local record or request made elsewhere).
    func cancel(requestId: String, source: RoleSource, account: Account) async -> String? {
        let key = requestId.lowercased()
        cancellingRequests.insert(key)
        defer { cancellingRequests.remove(key) }
        do {
            guard let pim = try PIMService(sources: sources(for: account)).source(for: source) else {
                throw TokenError.consentRequired
            }
            try await pim.cancel(request: requestId)
            for record in account.records where record.remoteRequestId?.lowercased() == requestId.lowercased() {
                record.status = .canceled
                record.completedAt = .now
            }
            pending[account.id]?.removeAll { $0.id.lowercased() == requestId.lowercased() }
            try? context.save()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    // MARK: - Pending requests and retention

    /// Pending approvals: lists them, and updates local records whose request was decided meanwhile (T4.3).
    /// ARM has no status filter on requests, so the full listing only runs while History is open or when local
    /// requests are still undecided.
    func refreshPending(of account: Account, service: PIMService, failedSources: Set<RoleSource>) async {
        let undecided = account.records.filter(Self.needsPolling)
        guard historyVisible || !undecided.isEmpty else {
            pending[account.id] = []
            pendingErrors[account.id] = nil
            return
        }
        var list: [RemoteRequest] = []
        var failure: String?
        for source in service.sources where !failedSources.contains(source.source) {
            do {
                list += try await source.pendingRequests()
            } catch {
                failure = Self.message(for: error)
            }
        }
        pending[account.id] = list.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        pendingErrors[account.id] = failure
        let open = Set(list.map { $0.id.lowercased() })
        for record in undecided {
            guard let requestId = record.remoteRequestId, !open.contains(requestId.lowercased()),
                  let source = service.source(for: record.source),
                  let status = try? await source.status(ofRequest: requestId),
                  status != .pendingApproval, status != .sent,
                  // Checked after the await: a cancel from the app may have started or ended meanwhile.
                  !cancellingRequests.contains(requestId.lowercased()), Self.needsPolling(record) else { continue }
            let wasPending = record.status == .pendingApproval
            record.status = status
            if status == .provisioned {
                record.completedAt = .now
                // The approver's delay is not app speed: keep it out of the time-to-activation median.
                if wasPending { record.panelOpenedAt = nil }
            }
            try? context.save()   // the decision is recorded before it is announced
            guard wasPending, Date.now.timeIntervalSince(record.sentAt) < 86_400,
                  let text = RequestDecision.notification(status: status, roleName: record.displayRoleName,
                                                          scopeName: record.displayScopeName) else { continue }
            await notifications.notify(title: text.title, body: text.body)
        }
    }

    /// Requests still waiting for a decision, polled for 7 days at most (older ones may hold a name-only ARM id).
    static func needsPolling(_ record: ActivationRecord) -> Bool {
        (record.status == .pendingApproval || record.status == .sent) && record.remoteRequestId != nil
            && Date.now.timeIntervalSince(record.sentAt) < Double(Retention.pollDays) * 86_400
    }

    /// Deletes history older than the retention setting (pending requests are kept).
    func purgeHistory() {
        let records = (try? context.fetch(FetchDescriptor<ActivationRecord>())) ?? []
        Retention.markAbandoned(records)
        let expired = Retention.expired(records, days: accounts.settings.historyRetentionDays)
        for record in expired {
            context.delete(record)
        }
        // A justification is kept only while a record still holds it (TRD: deleted with history).
        let removed = Set(expired.map(\.id))
        let kept = records.filter { !removed.contains($0.id) }
        for role in (try? context.fetch(FetchDescriptor<EligibleRole>())) ?? [] where role.lastJustification != nil {
            if !kept.contains(where: { $0.eligibleRoleId == role.id && $0.justification == role.lastJustification }) {
                role.lastJustification = nil
            }
        }
        pruneDurations()
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
