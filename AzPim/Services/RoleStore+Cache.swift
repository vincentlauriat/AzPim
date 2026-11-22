import AzPimCore
import Foundation
import SwiftData

// MARK: - Cache

extension RoleStore {
    /// Replaces the cache of one account. Sources that failed keep their previous rows (offline / throttled).
    func apply(_ snapshot: AccountSnapshot, to account: Account, failedSources: Set<RoleSource>) {
        var existing = Dictionary(account.eligibleRoles.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [String: EligibleRole] = [:]
        for remote in snapshot.eligibilities {
            let role = existing.removeValue(forKey: remote.id)
                ?? EligibleRole(id: remote.id, account: account, source: remote.source, roleDefinitionId: remote.roleDefinitionId,
                                roleName: remote.roleName, scope: remote.scope, scopeName: remote.scopeName,
                                scopeType: remote.scopeType, memberType: remote.memberType)
            if role.modelContext == nil { context.insert(role) }
            role.roleName = remote.roleName
            role.scopeName = remote.scopeName
            role.fetchedAt = snapshot.fetchedAt
            kept[remote.matchKey] = role
        }
        for stale in existing.values where !failedSources.contains(stale.source) {
            context.delete(stale)
        }

        // Assignments are updated in place, not deleted and recreated: views and actions holding a row
        // (popover, Deactivate in flight) keep a live object, and `notifiedAt` keeps its meaning.
        var current = Dictionary(account.activeAssignments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for remote in snapshot.assignments {
            let id = ActiveAssignment.localId(accountId: account.id, remoteId: remote.id)
            guard seen.insert(id).inserted else { continue }   // same instance twice in the answer
            let eligible = snapshot.eligibility(for: remote).flatMap { kept[$0.matchKey] }
            guard let row = current.removeValue(forKey: id) else {
                context.insert(ActiveAssignment(id: remote.id, account: account, source: remote.source, roleName: remote.roleName,
                                                scope: remote.scope, scopeName: remote.scopeName, assignmentType: remote.type,
                                                startAt: remote.startAt, endAt: remote.endAt, eligibleRole: eligible))
                continue
            }
            if row.endAt != remote.endAt { row.notifiedAt = nil }
            row.roleName = remote.roleName
            row.scopeName = remote.scopeName
            row.assignmentTypeRaw = remote.type.rawValue
            row.startAt = remote.startAt
            row.endAt = remote.endAt
            row.eligibleRole = eligible
            row.fetchedAt = snapshot.fetchedAt
        }
        for stale in current.values where !failedSources.contains(stale.source) {
            context.delete(stale)
        }
    }
}
