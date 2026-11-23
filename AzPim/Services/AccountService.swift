import AzPimCore
import Foundation
import SwiftData

/// Adds, removes and authenticates Accounts (Dual sign-in, ImplementationPlan T2.3–T2.5).
@MainActor
@Observable
final class AccountService {
    #if os(macOS)
    enum CLIStatus: Equatable {
        case unknown
        case notInstalled
        case notSignedIn(command: String)
        case signedIn(SignedInIdentity)
        case error(String)
    }

    #endif

    private let context: ModelContext
    #if os(macOS)
    private(set) var cliStatus: CLIStatus = .unknown
    #endif
    private var msalProviders: [UUID: MSALTokenProvider] = [:]
    /// MSAL accounts whose directory access was already tried silently in this launch (once is enough).
    @ObservationIgnored private var silentDirectoryTried: Set<UUID> = []

    init(context: ModelContext) {
        self.context = context
    }

    var settings: AppSettings { (try? AzPimStore.settings(in: context)) ?? AppSettings() }

    #if os(macOS)
    /// One provider per configured `az` path: its token cache and in-flight requests live across refreshes
    /// (a new provider would start an `az` process per call).
    @ObservationIgnored private var cachedCLI: (path: String?, provider: AzureCLITokenProvider)?

    var cliProvider: AzureCLITokenProvider {
        let path = settings.azCLIPath
        if let cachedCLI, cachedCLI.path == path { return cachedCLI.provider }
        let provider = AzureCLITokenProvider(configuredPath: path)
        cachedCLI = (path, provider)
        return provider
    }

    #endif

    /// Forgets the Azure CLI tokens read so far (a pass the user asked for); nothing to forget on iPhone.
    func clearCLICache() async {
        #if os(macOS)
        await cliProvider.clearCache()
        #endif
    }

    var msalClientId: String? { MSALTokenProvider.configuredClientId(override: settings.customClientId) }
    var isMSALConfigured: Bool { msalClientId != nil }

    // MARK: - Azure CLI

    #if os(macOS)

    /// Detects the CLI and its session (Onboarding preselection, Accounts Settings).
    func refreshCLIStatus() async {
        let provider = cliProvider
        guard provider.locateCLI() != nil else {
            cliStatus = .notInstalled
            return
        }
        do {
            cliStatus = .signedIn(try await provider.identity(tenantId: nil))
        } catch TokenError.cliNotSignedIn(let command) {
            cliStatus = .notSignedIn(command: command)
        } catch TokenError.cliNotFound {
            cliStatus = .notInstalled
        } catch {
            cliStatus = .error(Self.message(for: error))
        }
    }

    @discardableResult
    func addCLIAccount(tenantId: String? = nil) async throws -> Account {
        let identity = try await cliProvider.identity(tenantId: tenantId)
        return try upsert(identity: identity, mode: .azureCLI, homeAccountId: nil, clientId: nil)
    }

    #endif

    // MARK: - MSAL

    @discardableResult
    func addMSALAccount() async throws -> Account {
        guard let clientId = msalClientId else { throw TokenError.notConfigured }
        let provider = try MSALTokenProvider(clientId: clientId)
        let identity = try await provider.signIn()
        let account = try upsert(identity: identity, mode: .msal, homeAccountId: provider.homeAccountId,
                                 clientId: clientId)
        msalProviders[account.id] = provider
        // Entra roles and PIM groups right away, as "Enable Entra roles" would. A cancel or a failure there must
        // not undo the sign-in: the account keeps the button as fallback.
        if account.directoryAccess == .notRequested {
            try? await enableDirectoryAccess(for: account)
        }
        return account
    }

    /// "Enable Entra roles": incremental consent for directory scopes. Tries the token cache first, so an
    /// already consented tenant opens no window.
    func enableDirectoryAccess(for account: Account) async throws {
        let provider = try msalProvider(for: account)
        do {
            let cached: Bool
            do {
                cached = try await provider.silentDirectoryAccess(tenantId: account.tenantId)
            } catch TokenError.consentRequired {
                throw TokenError.consentRequired   // the prompt would not help: admin consent is missing
            } catch {
                cached = false
            }
            if !cached { try await provider.requestDirectoryAccess(tenantId: account.tenantId) }
            account.directoryAccess = .enabled
        } catch TokenError.consentRequired {
            account.directoryAccess = .consentRequired
        }
        try context.save()
    }

    /// Existing MSAL accounts still without directory access: one silent attempt per launch, never a window.
    /// Any answer other than a token (consent missing, interaction needed, network) leaves the state and the
    /// "Enable Entra roles" button as they are.
    func trySilentDirectoryAccess(for account: Account) async {
        guard account.mode == .msal, account.directoryAccess == .notRequested,
              silentDirectoryTried.insert(account.id).inserted,
              let provider = try? msalProvider(for: account),
              (try? await provider.silentDirectoryAccess(tenantId: account.tenantId)) == true,
              account.modelContext != nil, !account.isDeleted else { return }
        account.directoryAccess = .enabled
        try? context.save()
    }

    // MARK: - Common

    func provider(for account: Account) throws -> any TokenProvider {
        switch account.mode {
        #if os(macOS)
        case .azureCLI: cliProvider
        #else
        // No Azure CLI on iPhone: such an account cannot be added there (no `az`, no `Process`).
        case .azureCLI: throw TokenError.cliNotFound
        #endif
        case .msal: try msalProvider(for: account)
        }
    }

    /// Removes an account. For MSAL the token cache is purged first; if that fails the account is kept
    /// and the error is shown, so no orphaned credentials stay in the Keychain.
    func remove(_ account: Account) throws {
        if account.mode == .msal { try msalProvider(for: account).signOut() }
        msalProviders[account.id] = nil
        context.delete(account)
        try context.save()
    }

    /// Settings › Privacy (TRD › Security): signs out every account, then deletes accounts, roles, favorites, history
    /// and preferences from this Mac. Stops at the first MSAL sign-out failure (no orphaned credentials).
    func deleteAllLocalData() throws {
        for account in try context.fetch(FetchDescriptor<Account>()) {
            try remove(account)
        }
        try context.delete(model: Favorite.self)
        try context.delete(model: ActivationRecord.self)
        try context.delete(model: EligibleRole.self)
        try context.delete(model: ActiveAssignment.self)
        try context.delete(model: AppSettings.self)
        try context.save()
        _ = try AzPimStore.settings(in: context)   // fresh defaults; onboarding shows again at next launch
    }

    private func msalProvider(for account: Account) throws -> MSALTokenProvider {
        if let existing = msalProviders[account.id] { return existing }
        // Use the client the account signed in with; fall back to the current one for older rows.
        guard let clientId = account.msalClientId ?? msalClientId else { throw TokenError.notConfigured }
        let provider = try MSALTokenProvider(clientId: clientId, homeAccountId: account.msalHomeAccountId)
        msalProviders[account.id] = provider
        return provider
    }

    /// Same tenant + object id + mode = same account (BackendSchema unique index).
    private func upsert(identity: SignedInIdentity, mode: SignInMode, homeAccountId: String?,
                        clientId: String?) throws -> Account {
        let candidate = Account(mode: mode, upn: identity.upn, objectId: identity.objectId, tenantId: identity.tenantId,
                                tenantName: identity.tenantName, msalHomeAccountId: homeAccountId, msalClientId: clientId)
        let existing = try context.fetch(FetchDescriptor<Account>())
        if let match = existing.first(where: { $0.identityKey == candidate.identityKey }) {
            match.upn = identity.upn
            match.tenantName = identity.tenantName ?? match.tenantName
            match.msalHomeAccountId = homeAccountId ?? match.msalHomeAccountId
            match.msalClientId = clientId ?? match.msalClientId
            try context.save()
            return match
        }
        candidate.sortOrder = existing.count
        context.insert(candidate)
        try context.save()
        return candidate
    }

    static func message(for error: Error) -> String {
        switch error as? TokenError {
        case .cliNotFound: String(localized: "Azure CLI not found. Install it or choose its location in Settings.")
        case .cliNotSignedIn(let command): String(localized: "Azure CLI session expired or missing — run `\(command)`.")
        case .interactionRequired: String(localized: "Your organization requires you to sign in again (MFA).")
        case .cliStepUp(let command): String(localized: "Your organization requires a new sign-in (MFA) — run `\(command)` in Terminal.")
        case .consentRequired: String(localized: "Admin consent required in this tenant.")
        case .notConfigured: String(localized: "Microsoft sign-in is not configured in this build (no client ID).")
        case .cancelled: String(localized: "Sign-in cancelled.")
        case .timedOut: String(localized: "The request timed out.")
        case .failed(let message): message
        case nil: error.localizedDescription
        }
    }
}
