import Foundation

/// Shortcuts / App Intents activation (1.0 item 4): what « Activate role » may send. Unlike a quick activation it can
/// ask for a missing justification or ticket, but it never sends a request its policy would refuse, nor one decided on
/// a policy that was never read.
public enum IntentActivation: Equatable, Sendable {
    /// Ready: the exact input to confirm, then send.
    case send(ActivationInput)
    /// The policy requires a justification and none was given: ask for it.
    case needsJustification
    /// The policy requires a ticket and no ticket system was given: ask for it.
    case needsTicketSystem
    /// The policy requires a ticket and no ticket number was given: ask for it.
    case needsTicket
    /// Nothing can be sent.
    case refused(Refusal)

    public enum Refusal: Equatable, Sendable {
        /// Settings › Advanced turned off activation from links and Shortcuts.
        case disabled
        /// The role is active right now.
        case alreadyActive
        /// The policy could not be read: its defaults are not facts.
        case unknownPolicy
        /// A request in progress or waiting, offline, or a field the policy refuses (too long).
        case blocked(ActivationBlock)
    }

    public struct Facts: Sendable {
        public var allowed: Bool
        public var policy: RolePolicy
        public var policyKnown: Bool
        public var active = false
        /// Duration last chosen for the role (ISO 8601), if any.
        public var lastDuration: String?
        /// Duration asked by the shortcut, in minutes; nil for the default (last used, else 1 h).
        public var requestedMinutes: Int?
        public var justification = ""
        /// Ticket system: prefilled with the one last used in the role's tenant, or asked.
        public var ticketSystem = ""
        public var ticket = ""
        public var inProgress = false
        public var pending = false
        public var offline = false

        public init(allowed: Bool, policy: RolePolicy, policyKnown: Bool, active: Bool = false, lastDuration: String? = nil,
                    requestedMinutes: Int? = nil, justification: String = "", ticketSystem: String = "", ticket: String = "",
                    inProgress: Bool = false, pending: Bool = false, offline: Bool = false) {
            self.allowed = allowed
            self.policy = policy
            self.policyKnown = policyKnown
            self.active = active
            self.lastDuration = lastDuration
            self.requestedMinutes = requestedMinutes
            self.justification = justification
            self.ticketSystem = ticketSystem
            self.ticket = ticket
            self.inProgress = inProgress
            self.pending = pending
            self.offline = offline
        }
    }

    /// Duration sent: the one asked, else the role's default, always within [one step, policy maximum].
    public static func minutes(_ facts: Facts) -> Int {
        facts.requestedMinutes.map { ActivationDuration.clamp($0, policyMax: facts.policy.maxDuration) }
            ?? ActivationDuration.defaultMinutes(lastUsed: facts.lastDuration, policyMax: facts.policy.maxDuration)
    }

    /// In this order: the setting, already active, a request in progress or waiting, offline, the policy, the missing
    /// fields (asked one at a time), then the limits `ActivationBlock` checks. A justification given but not required
    /// is sent as typed; none is ever filled in from an earlier request.
    public static func decide(_ facts: Facts) -> IntentActivation {
        guard facts.allowed else { return .refused(.disabled) }
        if facts.active { return .refused(.alreadyActive) }
        if facts.inProgress { return .refused(.blocked(.inProgress)) }
        if facts.pending { return .refused(.blocked(.pending)) }
        if facts.offline { return .refused(.blocked(.offline)) }
        guard facts.policyKnown else { return .refused(.unknownPolicy) }
        let justification = facts.justification.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticket = facts.ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = facts.ticketSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        if facts.policy.requiresJustification, justification.isEmpty { return .needsJustification }
        if facts.policy.requiresTicket, system.isEmpty { return .needsTicketSystem }
        if facts.policy.requiresTicket, ticket.isEmpty { return .needsTicket }
        let minutes = minutes(facts)
        let block = ActivationBlock.reason(.init(minutes: minutes, policyMax: facts.policy.maxDuration,
                                                 requiresJustification: facts.policy.requiresJustification,
                                                 justification: justification, requiresTicket: facts.policy.requiresTicket,
                                                 ticketSystem: system, ticket: ticket))
        if let block { return .refused(.blocked(block)) }
        // A ticket only goes with a role whose policy asks for one (as the Activation Sheet sends it).
        let sendsTicket = facts.policy.requiresTicket && !ticket.isEmpty
        return .send(ActivationInput(duration: ActivationDuration.iso(minutes), justification: justification,
                                     ticketNumber: sendsTicket ? ticket : nil, ticketSystem: sendsTicket ? system : nil))
    }
}

/// Text returned by « Deactivate all » and « List active roles ».
public enum IntentSummary {
    /// One deactivation: the role as shown, and the error when it failed.
    public struct Deactivation: Sendable, Equatable {
        public let name: String
        public let error: String?

        public init(name: String, error: String? = nil) {
            self.name = name
            self.error = error
        }
    }

    /// « 2 of 3 deactivated — Owner: Azure refuses… ».
    public static func deactivated(_ results: [Deactivation], locale: Locale? = nil) -> String {
        let done = results.filter { $0.error == nil }.count
        var text = L10n.string("\(done) of \(results.count) deactivated", locale: locale)
        let failures = results.compactMap { result in result.error.map { "\(result.name): \($0)" } }
        if !failures.isEmpty { text += " — " + failures.joined(separator: "; ") }
        return text
    }

    /// « Contributor — Production, 42m left »; « no end date » for an activation without one.
    public static func activeLine(name: String, scope: String, endAt: Date?, now: Date = .now, locale: Locale? = nil) -> String {
        let left = endAt.map { end in
            L10n.string("\(ISODuration.label(max(0, end.timeIntervalSince(now)), locale: locale)) left", locale: locale)
        } ?? L10n.string("no end date", locale: locale)
        return "\(name) — \(scope), \(left)"
    }
}
