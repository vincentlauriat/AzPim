import Foundation

/// Ticket fields (1.0 item 7): the ticket system is remembered per tenant; the ticket number per role, and offered
/// again only within `window` of its last use (same incident). Nothing here is ever sent without the sheet.
public enum TicketRecall {
    /// A ticket number older than this is not prefilled: a new incident needs its own number.
    public static let window: TimeInterval = 8 * 3600

    /// A ticket number accepted by Azure for a role, and when.
    public struct Entry: Equatable, Sendable {
        public var number: String
        public var usedAt: Date

        public init(number: String, usedAt: Date) {
            self.number = number
            self.usedAt = usedAt
        }

        /// Used less than `window` ago (a date in the future, a changed clock, does not count).
        public func isRecent(at now: Date) -> Bool {
            let age = now.timeIntervalSince(usedAt)
            return age >= 0 && age < TicketRecall.window
        }
    }

    /// Ticket number to prefill: the most recent of `entries` used within `window`, else empty.
    public static func prefill(_ entries: [Entry?], now: Date = .now) -> String {
        entries.compactMap { $0 }.filter { $0.isRecent(at: now) }.max { $0.usedAt < $1.usedAt }?.number ?? ""
    }

    /// Key of the ticket system of a tenant.
    public static func tenantKey(_ tenantId: String) -> String { tenantId.lowercased() }

    /// Ticket numbers of roles still cached and still recent: an older one would never be offered again.
    public static func pruned(_ entries: [String: Entry], keeping keys: Set<String>, now: Date = .now) -> [String: Entry] {
        entries.filter { keys.contains($0.key) && $0.value.isRecent(at: now) }
    }

    /// Preferences form (`PreferenceKeys.lastTickets`): `[roleKey: ["number": String, "usedAt": Date]]`.
    public static func encode(_ entries: [String: Entry]) -> [String: [String: Any]] {
        entries.mapValues { ["number": $0.number, "usedAt": $0.usedAt] }
    }

    /// Values of another shape are ignored.
    public static func decode(_ raw: [String: Any]?) -> [String: Entry] {
        (raw ?? [:]).compactMapValues { value in
            guard let dict = value as? [String: Any], let number = dict["number"] as? String,
                  let usedAt = dict["usedAt"] as? Date else { return nil }
            return Entry(number: number, usedAt: usedAt)
        }
    }
}

/// What the grouped favorite sheet asked once for all the roles of a favorite.
public struct FavoriteAnswers: Equatable, Sendable {
    public var justification: String
    public var ticketSystem: String
    public var ticketNumber: String

    public init(justification: String = "", ticketSystem: String = "", ticketNumber: String = "") {
        self.justification = justification
        self.ticketSystem = ticketSystem
        self.ticketNumber = ticketNumber
    }
}

/// What a favorite run needs from the user before it can send every role.
public struct FavoriteNeeds: Equatable, Sendable {
    /// A role requires a justification and has neither its own nor a last one.
    public var justification = false
    /// A role requires a ticket.
    public var ticket = false

    public init(justification: Bool = false, ticket: Bool = false) {
        self.justification = justification
        self.ticket = ticket
    }

    /// The grouped sheet must open first.
    public var any: Bool { justification || ticket }
}

extension FavoriteRun {
    /// One role of a favorite that would be sent (not already active, not already waiting).
    public struct Pending: Sendable {
        public var item: FavoriteItem
        public var policy: RolePolicy
        public var lastJustification: String?

        public init(item: FavoriteItem, policy: RolePolicy, lastJustification: String?) {
            self.item = item
            self.policy = policy
            self.lastJustification = lastJustification
        }
    }

    /// What the grouped sheet must ask before the run.
    public static func needs(_ roles: [Pending]) -> FavoriteNeeds {
        var needs = FavoriteNeeds()
        for role in roles {
            if role.policy.requiresTicket { needs.ticket = true }
            if role.policy.requiresJustification,
               Validation.justification(ownJustification(role.item, last: role.lastJustification), required: true) != nil {
                needs.justification = true
            }
        }
        return needs
    }

    /// Why the grouped sheet cannot send yet, nil when it can (same sentences as the Activation Sheet).
    public static func block(_ needs: FavoriteNeeds, answers: FavoriteAnswers) -> ActivationBlock? {
        ActivationBlock.fieldsReason(requiresJustification: needs.justification, justification: answers.justification,
                                     requiresTicket: needs.ticket, ticketSystem: answers.ticketSystem,
                                     ticket: answers.ticketNumber)
    }

    static func ownJustification(_ item: FavoriteItem, last: String?) -> String {
        (item.justification?.isEmpty == false ? item.justification : last) ?? ""
    }
}

extension ActivationInput {
    /// `ticketInfo` of the ARM and Graph activation requests (same shape on both), nil without a ticket number.
    /// The system is left out when empty: a made-up one would end up in the tenant's audit log.
    public var ticketInfo: [String: String]? {
        let number = (ticketNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return nil }
        var info = ["ticketNumber": number]
        let system = (ticketSystem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { info["ticketSystem"] = system }
        return info
    }
}
