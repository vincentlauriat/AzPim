import Foundation

/// UI state of an error (AppFlow › Empty and blocked states, ImplementationPlan T5.1).
public enum ErrorKind: Hashable, Sendable {
    case offline
    /// Microsoft or the Azure CLI did not answer in time: one account, not the network (no "Offline" state).
    case timedOut
    case throttled(retryAfter: TimeInterval?)
    case cliNotFound
    case cliExpired(command: String)
    /// MFA / authentication context needed by an Azure CLI account: carries the `az login` command to copy.
    case cliStepUp(command: String)
    case interactionRequired
    case consentRequired
    case forbidden(String)
    case other(String)

    public static func classify(_ error: Error) -> ErrorKind {
        if let token = error as? TokenError { return classify(token) }
        if let pim = error as? PIMError {
            switch pim {
            case .throttled(let retryAfter): return .throttled(retryAfter: retryAfter)
            case .http(403, _, let message): return .forbidden(message)
            default: return .other(pim.userMessage)
            }
        }
        if let url = error as? URLError {
            if url.code == .timedOut { return .timedOut }
            if offlineCodes.contains(url.code) { return .offline }
        }
        return .other(error.localizedDescription)
    }

    static func classify(_ token: TokenError) -> ErrorKind {
        switch token {
        case .cliNotFound: return .cliNotFound
        case .cliNotSignedIn(let command): return .cliExpired(command: command)
        case .interactionRequired: return .interactionRequired
        case .cliStepUp(let command): return .cliStepUp(command: command)
        case .consentRequired: return .consentRequired
        case .timedOut: return .timedOut
        case .notConfigured: return .other("Microsoft sign-in is not configured in this build (no client ID).")
        case .cancelled: return .other("Sign-in cancelled.")
        case .failed(let message): return .other(message)
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed
    ]

    /// Terminal command the banner offers to copy (Azure CLI sign-in), if any.
    public var command: String? {
        switch self {
        case .cliExpired(let command), .cliStepUp(let command): command
        default: nil
        }
    }

    /// Short English text for banners and rows.
    public var message: String {
        switch self {
        case .offline: "Offline."
        case .timedOut: "Microsoft did not answer in time — try again."
        case .throttled(let retryAfter):
            "Microsoft is throttling requests — try again in \(Int(retryAfter ?? 30)) s."
        case .cliNotFound: "Azure CLI not found. Install it or choose its location in Settings."
        case .cliExpired(let command): "Azure CLI session expired — run `\(command)`."
        case .cliStepUp(let command): "Your organization requires a new sign-in (MFA) — run `\(command)` in Terminal, then refresh."
        case .interactionRequired: "Your organization requires you to sign in again (MFA)."
        case .consentRequired: "Admin consent required in this tenant."
        case .forbidden(let detail): "Not allowed by your tenant policy: \(detail)"
        case .other(let text): text
        }
    }
}
