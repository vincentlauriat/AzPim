import Foundation

/// Least-privilege activation durations (1.0 item 6): the last duration used for a role, else 1 h, always capped by
/// the policy maximum, chosen in 15-minute steps. Durations are whole minutes.
public enum ActivationDuration {
    /// Step of the duration stepper.
    public static let stepMinutes = 15
    /// Default without a remembered duration.
    public static let fallbackMinutes = 60
    /// Cap when the policy maximum is unknown (not read yet): the app's historical default.
    public static let unknownPolicyMaxMinutes = 8 * 60

    /// Policy maximum in minutes (`unknownPolicyMaxMinutes` when unknown or unreadable).
    public static func maxMinutes(policyMax: String?) -> Int {
        guard let seconds = policyMax.flatMap(ISODuration.seconds) else { return unknownPolicyMaxMinutes }
        return max(1, Int((seconds / 60).rounded(.down)))
    }

    /// Lowest value of the stepper: one step, or the policy maximum when it is shorter.
    public static func minMinutes(policyMax: String?) -> Int {
        min(stepMinutes, maxMinutes(policyMax: policyMax))
    }

    /// The duration to preselect: the last one used for the role, else 1 h, within [one step, policy maximum].
    public static func defaultMinutes(lastUsed: String?, policyMax: String?) -> Int {
        let wanted = lastUsed.flatMap(ISODuration.seconds).map { Int(($0 / 60).rounded()) } ?? fallbackMinutes
        return clamp(wanted, policyMax: policyMax)
    }

    public static func clamp(_ minutes: Int, policyMax: String?) -> Int {
        min(max(minutes, minMinutes(policyMax: policyMax)), maxMinutes(policyMax: policyMax))
    }

    /// One stepper tap: up or down to the next 15-minute mark, within [one step, policy maximum]. A maximum off the
    /// grid (80 min) is reachable going up, and going down from it lands on the grid (75 min).
    public static func step(_ minutes: Int, upward: Bool, policyMax: String?) -> Int {
        let next: Int
        if upward {
            next = (minutes / stepMinutes + 1) * stepMinutes
        } else {
            next = minutes % stepMinutes == 0 ? minutes - stepMinutes : minutes / stepMinutes * stepMinutes
        }
        return clamp(next, policyMax: policyMax)
    }

    public static func iso(_ minutes: Int) -> String { ISODuration.string(TimeInterval(minutes * 60)) }

    /// Key of an eligible role across refreshes and sign-ins: tenant + source + role definition (name when missing)
    /// + scope, ignoring case. Not the row id nor the account: the same role read through an Azure CLI account and
    /// then through the Microsoft sign-in that supersedes it keeps its remembered duration. Nil when the role has
    /// neither a definition id nor a meaningful name.
    public static func roleKey(tenantId: String, source: RoleSource, roleDefinitionId: String?, roleName: String,
                               scope: String) -> String? {
        RoleMerge.key(identity: AccountSupersede.normalized(tenantId), source: source, roleDefinitionId: roleDefinitionId,
                      roleName: roleName, scope: scope)
    }
}

/// Why the Activate button is disabled, as one sentence shown under it. Nil when the request can be sent.
public enum ActivationBlock: Equatable, Sendable {
    case inProgress
    case pending
    case offline
    case durationTooLong(maxMinutes: Int)
    case durationTooShort
    case justificationRequired
    case justificationTooLong
    case ticketRequired
    case ticketTooLong

    public struct Facts: Sendable {
        public var inProgress = false
        public var pending = false
        public var offline = false
        public var minutes: Int
        public var policyMax: String?
        public var requiresJustification: Bool
        public var justification = ""
        public var requiresTicket = false
        public var ticket = ""

        public init(inProgress: Bool = false, pending: Bool = false, offline: Bool = false, minutes: Int,
                    policyMax: String?, requiresJustification: Bool, justification: String = "",
                    requiresTicket: Bool = false, ticket: String = "") {
            self.inProgress = inProgress
            self.pending = pending
            self.offline = offline
            self.minutes = minutes
            self.policyMax = policyMax
            self.requiresJustification = requiresJustification
            self.justification = justification
            self.requiresTicket = requiresTicket
            self.ticket = ticket
        }
    }

    /// The first reason, in this order: a request in progress, one already waiting, offline, the duration, the
    /// justification, the ticket.
    public static func reason(_ facts: Facts) -> ActivationBlock? {
        if facts.inProgress { return .inProgress }
        if facts.pending { return .pending }
        if facts.offline { return .offline }
        return formReason(facts)
    }

    private static func formReason(_ facts: Facts) -> ActivationBlock? {
        switch Validation.duration(ActivationDuration.iso(facts.minutes), policyMax: facts.policyMax) {
        case .failure(.exceedsPolicy(let max)): return .durationTooLong(maxMinutes: Int(max / 60))
        case .failure: return .durationTooShort
        case .success: break
        }
        switch Validation.justification(facts.justification, required: facts.requiresJustification) {
        case .empty?: return .justificationRequired
        case .some: return .justificationTooLong
        case nil: break
        }
        switch Validation.ticketNumber(facts.ticket, required: facts.requiresTicket) {
        case .empty?: return .ticketRequired
        case .some: return .ticketTooLong
        case nil: return nil
        }
    }

    public var message: String {
        switch self {
        case .inProgress: "A request for this role is already in progress."
        case .pending: "A request for this role is already waiting for approval or confirmation."
        case .offline: "You're offline: activation needs a connection to Microsoft."
        case .durationTooLong(let max): "The policy allows \(ISODuration.label(TimeInterval(max * 60))) at most."
        case .durationTooShort: "Azure needs at least 5 minutes."
        case .justificationRequired: "The policy requires a justification."
        case .justificationTooLong: "The justification is limited to 500 characters."
        case .ticketRequired: "The policy requires a ticket number."
        case .ticketTooLong: "The ticket number is limited to 100 characters."
        }
    }
}
