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
    public init(activeCount: Int, nextExpiry: String?, pendingCount: Int) {
        active = "\(activeCount) active"
        expiry = nextExpiry.map { "next expiry in \($0)" }
        pending = pendingCount > 0 ? "\(pendingCount) pending" : nil
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

    public var spokenPending: String? {
        pendingCount > 0 ? "\(pendingCount) request\(pendingCount == 1 ? "" : "s") waiting for approval" : nil
    }
}

/// Notification posted when a request that waited for approval is decided.
public enum RequestDecision {
    /// Title and body, nil for a status that is not a decision.
    public static func notification(status: RequestStatus, roleName: String,
                                    scopeName: String) -> (title: String, body: String)? {
        switch status {
        case .provisioned: ("Request approved: \(roleName)", "\(scopeName) — the role is active.")
        case .denied: ("Request denied: \(roleName)", "\(scopeName) — the approver denied the request.")
        case .failed: ("Request expired or failed: \(roleName)", "\(scopeName) — no approval in time, or the request failed.")
        case .canceled: ("Request canceled: \(roleName)", "\(scopeName) — the request was canceled or revoked.")
        case .sent, .pendingApproval: nil
        }
    }
}
