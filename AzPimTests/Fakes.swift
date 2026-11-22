@testable import AzPim
import AzPimCore
import Foundation
import SwiftData
import UserNotifications

// MARK: - PIM source

/// One PIM source of one account: what Azure / Graph would answer, and the requests the store sent.
actor FakeSource: PIMSource {
    nonisolated let source: RoleSource
    var eligibleList: [RemoteEligibility] = []
    var assignmentList: [RemoteAssignment] = []
    /// Refresh failure (eligibilities and assignments).
    var refreshError: Error?
    var policyResult: Result<RolePolicy, Error> = .success(RolePolicy(maxDuration: "PT8H"))
    /// Activation answers per eligibility id, consumed in order; when none is left the request succeeds.
    var activateResults: [String: [Result<RequestOutcome, Error>]] = [:]
    var deactivateResult: Result<RequestOutcome, Error> = .success(RequestOutcome(requestId: "deact", status: .provisioned))
    /// The deactivated activation disappears from the next refresh (Azure may still report it for a few seconds).
    var removeOnDeactivate = true
    /// A successful activation shows up in the next refresh, with a new instance id.
    var addOnActivate = true
    var pending: [RemoteRequest] = []
    var requestStatus: Result<RequestStatus, Error> = .success(.pendingApproval)
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var pendingCount = 0

    init(_ source: RoleSource) {
        self.source = source
    }

    func set(eligible: [RemoteEligibility]? = nil, assignments: [RemoteAssignment]? = nil) {
        if let eligible { eligibleList = eligible }
        if let assignments { assignmentList = assignments }
    }

    /// Refreshes fail with this error from now on (nil: they succeed again).
    func fail(with error: Error?) {
        refreshError = error
    }

    func set(activate results: [Result<RequestOutcome, Error>], for eligibilityId: String) {
        activateResults[eligibilityId] = results
    }

    func set(deactivate result: Result<RequestOutcome, Error>, removes: Bool = true) {
        deactivateResult = result
        removeOnDeactivate = removes
    }

    func set(requestStatus status: Result<RequestStatus, Error>) {
        requestStatus = status
    }

    func eligibilities() async throws -> [RemoteEligibility] {
        if let refreshError { throw refreshError }
        return eligibleList
    }

    func assignments() async throws -> [RemoteAssignment] {
        if let refreshError { throw refreshError }
        return assignmentList
    }

    func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy {
        try policyResult.get()
    }

    func activate(_ eligibility: RemoteEligibility, principalId: String, input: ActivationInput) async throws -> RequestOutcome {
        activateCount += 1
        var queue = activateResults[eligibility.id] ?? []
        let result = queue.isEmpty ? .success(RequestOutcome(requestId: "req-\(activateCount)", status: .provisioned))
            : queue.removeFirst()
        activateResults[eligibility.id] = queue
        let outcome = try result.get()
        if addOnActivate, outcome.status == .provisioned {
            assignmentList.append(Fixture.activation(eligibility, instance: "\(eligibility.id)-new-\(activateCount)",
                                                     start: .now, end: .now.addingTimeInterval(8 * 3600)))
        }
        return outcome
    }

    func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome {
        deactivateCount += 1
        let outcome = try deactivateResult.get()
        if removeOnDeactivate { assignmentList.removeAll { $0.linkedEligibilityId == eligibility.id } }
        return outcome
    }

    func pendingRequests() async throws -> [RemoteRequest] {
        pendingCount += 1
        return pending
    }

    func status(ofRequest id: String) async throws -> RequestStatus {
        try requestStatus.get()
    }

    func cancel(request id: String) async throws {}
}

// MARK: - Fixtures

enum Fixture {
    static func eligibility(_ id: String, source: RoleSource = .azureResource, role: String = "Contributor")
        -> RemoteEligibility {
        RemoteEligibility(id: id, source: source, roleDefinitionId: "rd-\(id)", roleName: role, scope: "/scope/\(id)",
                          scopeName: "Scope \(id)", scopeType: "subscription", memberType: .direct)
    }

    static func activation(_ eligibility: RemoteEligibility, instance: String,
                           start: Date = .now.addingTimeInterval(-3600),
                           end: Date = .now.addingTimeInterval(1800)) -> RemoteAssignment {
        RemoteAssignment(id: instance, source: eligibility.source, roleDefinitionId: eligibility.roleDefinitionId,
                         roleName: eligibility.roleName, scope: eligibility.scope, scopeName: eligibility.scopeName,
                         type: .activated, startAt: start, endAt: end, linkedEligibilityId: eligibility.id)
    }

    /// Unsigned JWT carrying the claims the store checks (`oid`, `tid`).
    static func jwt(objectId: String, tenantId: String) -> String {
        let payload = try? JSONSerialization.data(withJSONObject: ["oid": objectId, "tid": tenantId])
        let encoded = (payload ?? Data()).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "e30.\(encoded).sig"
    }
}

// MARK: - Tokens

/// Tokens of one identity; records the claims of every request.
final class FakeTokenProvider: TokenProvider, @unchecked Sendable {
    let mode: SignInMode
    private let objectId: String, tenantId: String
    private let lock = NSLock()
    private var seenClaims: [String?] = []

    init(mode: SignInMode, objectId: String, tenantId: String) {
        self.mode = mode
        self.objectId = objectId
        self.tenantId = tenantId
    }

    var claims: [String?] { lock.withLock { seenClaims } }

    func token(for resource: Resource, tenantId: String?, claims: String?) async throws -> AccessToken {
        lock.withLock { seenClaims.append(claims) }
        return AccessToken(value: Fixture.jwt(objectId: objectId, tenantId: self.tenantId),
                           expiresOn: .now.addingTimeInterval(3600))
    }

    func identity(tenantId: String?) async throws -> SignedInIdentity {
        SignedInIdentity(upn: "user@test", objectId: objectId, tenantId: self.tenantId, tenantName: nil)
    }
}

// MARK: - HTTP

/// Graph / ARM answers for the real clients: POSTs consume `posts` in order, every GET gets an empty list.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Answer {
        let status: Int
        let json: [String: Any]
    }

    private let lock = NSLock()
    private var posts: [Answer]
    private var sentPosts: [URL] = []

    init(posts: [Answer]) {
        self.posts = posts
    }

    var postURLs: [URL] { lock.withLock { sentPosts } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer = lock.withLock {
            guard request.httpMethod == "POST" else { return Answer(status: 200, json: ["value": []]) }
            if let url = request.url { sentPosts.append(url) }
            return posts.isEmpty ? Answer(status: 500, json: [:]) : posts.removeFirst()
        }
        let data = try JSONSerialization.data(withJSONObject: answer.json)
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

// MARK: - Notifications

/// Records what the scheduler adds and removes; pending = added and not removed.
final class FakeNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingList: [LocalNotification] = []
    private var delivered: [LocalNotification] = []

    var pending: [LocalNotification] { lock.withLock { pendingList } }
    /// Immediate notifications (no delay).
    var immediate: [LocalNotification] { lock.withLock { delivered } }

    @MainActor func setUp(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {}

    func pendingIdentifiers() async -> [String] {
        lock.withLock { pendingList.map(\.id) }
    }

    func removePending(withIdentifiers ids: [String]) {
        lock.withLock { pendingList.removeAll { ids.contains($0.id) } }
    }

    func removeDelivered(withIdentifiers ids: [String]) {}

    func add(_ notification: LocalNotification) async {
        lock.withLock {
            if notification.delay == nil { delivered.append(notification) } else { pendingList.append(notification) }
        }
    }
}

// MARK: - Harness

/// A RoleStore on an in-memory store, with fake sources per account, instant recorded sleeps and a fake center.
@MainActor
final class Harness {
    let container: ModelContainer
    let store: RoleStore
    let center = FakeNotificationCenter()
    /// Sources per account id.
    var sources: [UUID: [FakeSource]] = [:]
    /// Durations the store waited for (nothing actually waits).
    private(set) var sleeps: [Duration] = []
    /// Runs inside each wait (a refresh landing during an Extend).
    var duringSleep: (@MainActor () async -> Void)?

    var context: ModelContext { container.mainContext }

    init() throws {
        container = try AzPimStore.makeContainer(inMemory: true)
        let accounts = AccountService(context: container.mainContext)
        store = RoleStore(context: container.mainContext, accounts: accounts,
                          notifications: NotificationScheduler(center: center))
        store.tokenProvider = { FakeTokenProvider(mode: $0.mode, objectId: $0.objectId, tenantId: $0.tenantId) }
        store.makeSources = { [unowned self] account, _, _ in self.sources[account.id] ?? [] }
        store.sleep = { [weak self] duration in await self?.slept(duration) }
    }

    private func slept(_ duration: Duration) async {
        sleeps.append(duration)
        await duringSleep?()
    }

    @discardableResult
    func addAccount(_ mode: SignInMode = .azureCLI, objectId: String = "oid-1", tenantId: String = "tenant-1",
                    sortOrder: Int = 0, sources kinds: [RoleSource] = [.azureResource]) -> (Account, [FakeSource]) {
        let account = Account(mode: mode, upn: "user@test", objectId: objectId, tenantId: tenantId, sortOrder: sortOrder)
        if mode == .msal { account.directoryAccess = .enabled }   // never a real MSAL provider (silent directory try)
        context.insert(account)
        try? context.save()
        let fakes = kinds.map(FakeSource.init)
        sources[account.id] = fakes
        return (account, fakes)
    }

    /// A background refresh, as the timer runs it.
    func refresh() async {
        await TokenInteraction.$isBackground.withValue(true) { await store.refresh() }
    }

    func role(_ account: Account, _ remoteId: String) -> EligibleRole? {
        store.eligibleRole(id: "\(account.id.uuidString)|\(remoteId)")
    }

    func records() -> [ActivationRecord] {
        (try? context.fetch(FetchDescriptor<ActivationRecord>(sortBy: [SortDescriptor(\.sentAt)]))) ?? []
    }
}

/// "Already active" refusal (Azure still reports the activation just ended).
let alreadyActive = PIMError.http(status: 400, code: "RoleAssignmentExists", message: "The role assignment already exists.")
