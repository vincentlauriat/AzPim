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
        case .notConfigured:
            return .other(L10n.string("Microsoft sign-in is not configured in this build (no client ID).", locale: nil))
        case .cancelled: return .other(L10n.string("Sign-in cancelled.", locale: nil))
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

    /// Short text for banners and rows, in the system language. Azure's own messages (`forbidden`, `other`) are shown
    /// as Microsoft wrote them.
    public var message: String { message(locale: nil) }

    public func message(locale: Locale?) -> String {
        switch self {
        case .offline: L10n.string("Offline.", locale: locale)
        case .timedOut: L10n.string("Microsoft did not answer in time — try again.", locale: locale)
        case .throttled(let retryAfter):
            L10n.string("Microsoft is throttling requests — try again in \(Self.wait(retryAfter ?? 30, locale: locale)).",
                        locale: locale)
        case .cliNotFound: L10n.string("Azure CLI not found. Install it or choose its location in Settings.", locale: locale)
        case .cliExpired(let command): L10n.string("Azure CLI session expired — run `\(command)`.", locale: locale)
        case .cliStepUp(let command):
            L10n.string("Your organization requires a new sign-in (MFA) — run `\(command)` in Terminal, then refresh.",
                        locale: locale)
        case .interactionRequired: L10n.string("Your organization requires you to sign in again (MFA).", locale: locale)
        case .consentRequired: L10n.string("Admin consent required in this tenant.", locale: locale)
        case .forbidden(let detail): L10n.string("Not allowed by your tenant policy: \(detail)", locale: locale)
        case .other(let text): text
        }
    }

    /// « 30 s », « 2 min »: the wait Microsoft asks for.
    static func wait(_ seconds: TimeInterval, locale: Locale?) -> String {
        Duration.seconds(Int(seconds.rounded()))
            .formatted(.units(allowed: [.minutes, .seconds], width: .condensedAbbreviated).locale(locale ?? .current))
    }
}
