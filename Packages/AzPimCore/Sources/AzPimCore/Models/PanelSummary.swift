import Foundation

/// Search field of the panel: a row matches when every word of the query appears in one of its fields (role name,
/// scope, PIM group name, role type), ignoring case and accents. An empty query matches every row.
public enum RoleSearch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func matches(_ query: String, fields: [String]) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let folded = fields.map(fold)
        return words.allSatisfy { word in folded.contains { $0.contains(word) } }
    }

    public static func isEmpty(_ query: String) -> Bool {
        query.allSatisfy(\.isWhitespace)
    }
}

/// One-line summary of the panel's hero card: « 2 active · next expiry in 42m · 1 pending ». Segments that do not
/// apply are left out.
public struct HeroSummary: Equatable, Sendable {
    public let active: String
    /// « next expiry in 42m », nil without a timed activation.
    public let expiry: String?
    /// « 1 pending », nil when no request waits for approval.
    public let pending: String?

    /// `nextExpiry`: the countdown of the activation ending first, already formatted.
    /// `locale` nil: the system language.
    public init(activeCount: Int, nextExpiry: String?, pendingCount: Int, locale: Locale? = nil) {
        active = L10n.string("\(activeCount) active", locale: locale)
        expiry = nextExpiry.map { L10n.string("next expiry in \($0)", locale: locale) }
        pending = pendingCount > 0 ? L10n.string("\(pendingCount) pending", locale: locale) : nil
    }

    public var line: String { [active, expiry, pending].compactMap { $0 }.joined(separator: " · ") }
}

/// What the menu bar label shows: the key (filled when nothing is active) and an hourglass while a request waits
/// for approval. Plain SF Symbols: the status item renders them as template images, legible on any menu bar.
public struct MenuBarBadge: Equatable, Sendable {
    public let activeCount: Int
    public let pendingCount: Int

    public init(activeCount: Int, pendingCount: Int) {
        self.activeCount = activeCount
        self.pendingCount = pendingCount
    }

    public var keySymbol: String { activeCount == 0 ? "key.fill" : "key.horizontal.fill" }
    /// Shown next to the key while a request waits for approval.
    public var pendingSymbol: String? { pendingCount > 0 ? "hourglass" : nil }

    public var spokenPending: String? { spokenPending(locale: nil) }

    public func spokenPending(locale: Locale?) -> String? {
        pendingCount > 0 ? L10n.string("\(pendingCount) requests waiting for approval", locale: locale) : nil
    }
}

/// Notification posted when a request that waited for approval is decided.
public enum RequestDecision {
    /// Title and body, nil for a status that is not a decision.
    public static func notification(status: RequestStatus, roleName: String, scopeName: String,
                                    locale: Locale? = nil) -> (title: String, body: String)? {
        switch status {
        case .provisioned:
            (L10n.string("Request approved: \(roleName)", locale: locale),
             L10n.string("\(scopeName) — the role is active.", locale: locale))
        case .denied:
            (L10n.string("Request denied: \(roleName)", locale: locale),
             L10n.string("\(scopeName) — the approver denied the request.", locale: locale))
        case .failed:
            (L10n.string("Request expired or failed: \(roleName)", locale: locale),
             L10n.string("\(scopeName) — no approval in time, or the request failed.", locale: locale))
        case .canceled:
            (L10n.string("Request canceled: \(roleName)", locale: locale),
             L10n.string("\(scopeName) — the request was canceled or revoked.", locale: locale))
        case .sent, .pendingApproval: nil
        }
    }
}
