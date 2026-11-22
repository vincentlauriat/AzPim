import Foundation

// One account per identity and one row per role: pure rules behind the panel, the Roles window, favorites and
// notifications, kept apart from SwiftData so they can be tested without a store.

/// What the supersede rule needs to know about an Account.
public struct AccountFacts: Sendable, Equatable {
    public let id: UUID
    public let mode: SignInMode
    public let tenantId: String
    public let upn: String

    public init(id: UUID, mode: SignInMode, tenantId: String, upn: String) {
        self.id = id
        self.mode = mode
        self.tenantId = tenantId
        self.upn = upn
    }

    /// The person behind the account: tenant + UPN, case-insensitive (the object id is the same too, but the UPN is
    /// what the user sees and what both sign-in modes always return).
    public var identity: String { AccountSupersede.identity(tenantId: tenantId, upn: upn) }
}

public enum AccountSupersede {
    public static func identity(tenantId: String, upn: String) -> String {
        "\(tenantId.trimmingCharacters(in: .whitespaces).lowercased())|\(upn.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Azure CLI accounts replaced by a Microsoft (MSAL) account of the same identity: `[CLI id: MSAL id]`.
    /// A superseded account is not refreshed and its roles are shown nowhere; removing the MSAL account brings it back.
    public static func superseded(_ accounts: [AccountFacts]) -> [UUID: UUID] {
        var msal: [String: UUID] = [:]
        for account in accounts where account.mode == .msal {
            msal[account.identity] = msal[account.identity] ?? account.id
        }
        var result: [UUID: UUID] = [:]
        for account in accounts where account.mode == .azureCLI {
            if let replacement = msal[account.identity] { result[account.id] = replacement }
        }
        return result
    }

    /// Local EligibleRole id (`<account id>|<remote id>`) of the same eligibility under the superseding account.
    /// The remote schedule id is the identity's, not the sign-in's, so favorites made on the CLI account keep working.
    /// Ids of accounts that are not superseded come back unchanged.
    public static func resolve(eligibleRoleId: String, superseded: [UUID: UUID]) -> String {
        guard let bar = eligibleRoleId.firstIndex(of: "|"),
              let account = UUID(uuidString: String(eligibleRoleId[..<bar])),
              let replacement = superseded[account] else { return eligibleRoleId }
        return replacement.uuidString + eligibleRoleId[bar...]
    }
}

/// What the merge rule needs to know about an ActiveAssignment.
public struct AssignmentFacts: Sendable, Equatable {
    public let id: String
    /// `AccountSupersede.identity` of the owning account.
    public let identity: String
    public let source: RoleSource
    /// Role definition id when the row carries one; nil falls back to the role name. Assignment rows in the store do
    /// not keep it, so the app passes nil and rows match on the name.
    public let roleDefinitionId: String?
    public let roleName: String
    public let scope: String
    public let type: AssignmentType
    public let endAt: Date?

    public init(id: String, identity: String, source: RoleSource, roleDefinitionId: String? = nil, roleName: String,
                scope: String, type: AssignmentType, endAt: Date?) {
        self.id = id
        self.identity = identity
        self.source = source
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.type = type
        self.endAt = endAt
    }

    public var key: String {
        RoleMerge.key(identity: identity, source: source, roleDefinitionId: roleDefinitionId, roleName: roleName, scope: scope)
    }
}

/// One shown row: the assignment to act on, and whether the same role is also held permanently.
public struct MergedAssignment: Sendable, Equatable {
    /// The activation when there is one (Deactivate and the countdown target it), else the permanent assignment.
    public let primaryId: String
    public let type: AssignmentType
    public let alsoPermanent: Bool
    /// Every row folded into this one, primary included.
    public let memberIds: [String]
}

public enum RoleMerge {
    public static func key(identity: String, source: RoleSource, roleDefinitionId: String?, roleName: String,
                           scope: String) -> String {
        let role = roleDefinitionId.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : "id:\($0)" }
            ?? "name:\(roleName.trimmingCharacters(in: .whitespaces))"
        return "\(identity)|\(source.rawValue)|\(role.lowercased())|\(scope.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Folds rows of the same identity, source, role and scope into one, in the order of their first row.
    /// An activation wins over a permanent assignment (the one ending last when there are several) and is marked
    /// `alsoPermanent` when a permanent assignment of the same role exists too.
    public static func merge(_ rows: [AssignmentFacts]) -> [MergedAssignment] {
        var order: [String] = []
        var groups: [String: [AssignmentFacts]] = [:]
        for row in rows {
            if groups[row.key] == nil { order.append(row.key) }
            groups[row.key, default: []].append(row)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            let activations = group.filter { $0.type == .activated }
            let primary = activations.max { ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture) } ?? first
            return MergedAssignment(primaryId: primary.id, type: primary.type,
                                    alsoPermanent: !activations.isEmpty && group.contains { $0.type == .assigned },
                                    memberIds: group.map(\.id))
        }
    }

    /// An eligible role already held: an activation linked to it, or any live assignment (activation or permanent)
    /// with the same identity, source, role and scope. `heldKeys` are the `AssignmentFacts.key` of the live rows.
    public static func isHeld(eligibleRoleId: String, key: String, linkedEligibleIds: Set<String>,
                              heldKeys: Set<String>) -> Bool {
        linkedEligibleIds.contains(eligibleRoleId) || heldKeys.contains(key)
    }
}

// MARK: - Model adapters

extension Account {
    public var facts: AccountFacts { AccountFacts(id: id, mode: mode, tenantId: tenantId, upn: upn) }
    public var identity: String { AccountSupersede.identity(tenantId: tenantId, upn: upn) }
}

extension ActiveAssignment {
    public var facts: AssignmentFacts {
        AssignmentFacts(id: id, identity: account?.identity ?? "", source: source, roleName: roleName, scope: scope,
                        type: assignmentType, endAt: endAt)
    }
}

extension EligibleRole {
    /// Same key as `ActiveAssignment.facts.key` (role name, not definition id: assignment rows do not keep it).
    public var heldKey: String {
        RoleMerge.key(identity: account?.identity ?? "", source: source, roleDefinitionId: nil, roleName: roleName, scope: scope)
    }
}
