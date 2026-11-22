import Foundation

// One account per identity and one row per role: pure rules behind the panel, the Roles window, favorites and
// notifications, kept apart from SwiftData so they can be tested without a store.

/// What the supersede rule needs to know about an Account.
public struct AccountFacts: Sendable, Equatable {
    public let id: UUID
    public let mode: SignInMode
    public let tenantId: String
    public let objectId: String
    public let upn: String
    /// Sources the account reads: Azure resources, plus Entra roles and PIM groups with directory access.
    public let sources: Set<RoleSource>
    /// Sources it has loaded successfully at least once (rows stored, or a refresh without error for that source).
    public let loaded: Set<RoleSource>

    public init(id: UUID, mode: SignInMode, tenantId: String, objectId: String = "", upn: String,
                sources: Set<RoleSource> = [.azureResource], loaded: Set<RoleSource> = []) {
        self.id = id
        self.mode = mode
        self.tenantId = tenantId
        self.objectId = objectId
        self.upn = upn
        self.sources = sources
        self.loaded = loaded
    }

    /// Same person: same tenant, and same object id (or, when either is missing or they differ, same UPN), ignoring case.
    public func isSameIdentity(as other: AccountFacts) -> Bool {
        guard AccountSupersede.normalized(tenantId) == AccountSupersede.normalized(other.tenantId) else { return false }
        let oid = AccountSupersede.normalized(objectId), otherOid = AccountSupersede.normalized(other.objectId)
        if !oid.isEmpty, oid == otherOid { return true }
        return AccountSupersede.normalized(upn) == AccountSupersede.normalized(other.upn)
    }
}

/// Which Azure CLI accounts a Microsoft (MSAL) sign-in of the same identity replaces, and for which sources.
public struct Supersession: Sendable, Equatable {
    /// `[CLI id: MSAL id]` for every CLI account with at least one superseded source.
    public let replacedBy: [UUID: UUID]
    /// Superseded sources per CLI account: their rows are shown nowhere.
    public let hiddenSources: [UUID: Set<RoleSource>]
    /// CLI accounts whose every source is superseded: not refreshed, greyed in Settings.
    public let retired: Set<UUID>

    public static let none = Supersession(replacedBy: [:], hiddenSources: [:], retired: [])

    public init(replacedBy: [UUID: UUID], hiddenSources: [UUID: Set<RoleSource>], retired: Set<UUID>) {
        self.replacedBy = replacedBy
        self.hiddenSources = hiddenSources
        self.retired = retired
    }

    /// Rows of this account and source are superseded (shown nowhere, never acted on).
    public func hides(_ accountId: UUID, _ source: RoleSource) -> Bool {
        hiddenSources[accountId]?.contains(source) == true
    }

    public func isRetired(_ accountId: UUID) -> Bool { retired.contains(accountId) }

    /// Local EligibleRole id (`<account id>|<remote id>`) of the same eligibility under the superseding account, when
    /// that source is superseded. The remote schedule id is the identity's, not the sign-in's, so favorites, requests
    /// and links made on the CLI account keep working. Other ids come back unchanged.
    public func resolve(eligibleRoleId: String, source: RoleSource) -> String {
        guard let bar = eligibleRoleId.firstIndex(of: "|"),
              let account = UUID(uuidString: String(eligibleRoleId[..<bar])),
              hides(account, source), let replacement = replacedBy[account] else { return eligibleRoleId }
        return replacement.uuidString + eligibleRoleId[bar...]
    }
}

public enum AccountSupersede {
    static func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Key of the person behind an account, for merging rows: tenant + object id (UPN when the object id is missing).
    public static func identity(tenantId: String, objectId: String, upn: String) -> String {
        let person = normalized(objectId).isEmpty ? "upn:\(normalized(upn))" : "oid:\(normalized(objectId))"
        return "\(normalized(tenantId))|\(person)"
    }

    /// A Microsoft (MSAL) account supersedes an Azure CLI account of the same identity, source by source, once it has
    /// loaded that source successfully at least once: until then (or while it keeps failing) the CLI rows stay.
    /// Removing the MSAL account brings the CLI account back.
    public static func supersession(_ accounts: [AccountFacts]) -> Supersession {
        let msal = accounts.filter { $0.mode == .msal }
        var replacedBy: [UUID: UUID] = [:], hidden: [UUID: Set<RoleSource>] = [:], retired = Set<UUID>()
        for cli in accounts where cli.mode == .azureCLI {
            guard let replacement = msal.first(where: { $0.isSameIdentity(as: cli) && !$0.loaded.isDisjoint(with: cli.sources) })
            else { continue }
            let sources = cli.sources.intersection(replacement.loaded)
            replacedBy[cli.id] = replacement.id
            hidden[cli.id] = sources
            if cli.sources.isSubset(of: sources) { retired.insert(cli.id) }
        }
        return Supersession(replacedBy: replacedBy, hiddenSources: hidden, retired: retired)
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
    /// Linked to an eligible role (an activation the app can deactivate and extend).
    public let linked: Bool

    public init(id: String, identity: String, source: RoleSource, roleDefinitionId: String? = nil, roleName: String,
                scope: String, type: AssignmentType, endAt: Date?, linked: Bool = false) {
        self.id = id
        self.identity = identity
        self.source = source
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.type = type
        self.endAt = endAt
        self.linked = linked
    }

    public var key: String {
        RoleMerge.key(identity: identity, source: source, roleDefinitionId: roleDefinitionId, roleName: roleName, scope: scope)
            ?? "unique|assignment:\(id)"
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
    /// Names the clients use when Azure or Graph did not expand the role definition: they say nothing about the role,
    /// so rows carrying them are never merged nor taken as proof that a role is held.
    public static let fallbackARMName = "Role"
    public static let fallbackEntraName = "Entra role"

    public static func isFallbackName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || [fallbackARMName, fallbackEntraName].contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Nil when there is neither a definition id nor a meaningful name: such a row matches nothing.
    public static func key(identity: String, source: RoleSource, roleDefinitionId: String?, roleName: String,
                           scope: String) -> String? {
        let definition = roleDefinitionId.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let role: String
        if let definition {
            role = "id:\(definition)"
        } else if isFallbackName(roleName) {
            return nil
        } else {
            role = "name:\(roleName.trimmingCharacters(in: .whitespaces))"
        }
        return "\(identity)|\(source.rawValue)|\(role.lowercased())|\(scope.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Folds rows of the same identity, source, role and scope into one, in the order of their first row.
    /// An activation wins over a permanent assignment (one linked to an eligible role first, then the one ending last)
    /// and is marked `alsoPermanent` when a permanent assignment of the same role exists too.
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
            let primary = activations.max { lhs, rhs in
                if lhs.linked != rhs.linked { return !lhs.linked }
                return (lhs.endAt ?? .distantFuture) < (rhs.endAt ?? .distantFuture)
            } ?? first
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
    /// `loaded`: sources this account has loaded at least once in this launch; stored rows count too.
    public func facts(loaded: Set<RoleSource> = []) -> AccountFacts {
        let stored = Set(eligibleRoles.map(\.source)).union(activeAssignments.map(\.source))
        let sources: Set<RoleSource> = directoryAccess == .enabled ? Set(RoleSource.allCases) : [.azureResource]
        return AccountFacts(id: id, mode: mode, tenantId: tenantId, objectId: objectId, upn: upn, sources: sources,
                            loaded: loaded.union(stored))
    }

    public var identity: String { AccountSupersede.identity(tenantId: tenantId, objectId: objectId, upn: upn) }
}

extension ActiveAssignment {
    public var facts: AssignmentFacts {
        AssignmentFacts(id: id, identity: account?.identity ?? "", source: source, roleName: roleName, scope: scope,
                        type: assignmentType, endAt: endAt, linked: eligibleRole != nil)
    }
}

extension EligibleRole {
    /// Same key as `ActiveAssignment.facts.key` (role name, not definition id: assignment rows do not keep it).
    public var heldKey: String {
        RoleMerge.key(identity: account?.identity ?? "", source: source, roleDefinitionId: nil, roleName: roleName, scope: scope)
            ?? "unique|eligible:\(id)"
    }
}
