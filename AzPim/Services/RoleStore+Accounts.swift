import AzPimCore
import Foundation
import SwiftData

/// One account per identity: what the store reads and acts on leaves out a superseded Azure CLI account.
extension RoleStore {
    /// Live activations of the accounts in use (never superseded rows): notifications, Extend, favorites.
    func activeActivations() -> [ActiveAssignment] {
        let all = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        let supersession = supersession()
        return all.filter { assignment in
            assignment.assignmentType == .activated && assignment.isLive()
                && assignment.account.map { !supersession.hides($0.id, assignment.source) } == true
        }
    }

    /// Azure CLI accounts replaced by a Microsoft sign-in of the same identity, source by source.
    func supersession(_ accounts: [Account]) -> Supersession {
        AccountSupersede.supersession(accounts.map { $0.facts(loaded: loadedSources[$0.id] ?? []) })
    }

    func supersession() -> Supersession {
        supersession((try? context.fetch(FetchDescriptor<Account>())) ?? [])
    }

    /// The eligible role an id stands for now: a role of a superseded Azure CLI account is the same eligibility under
    /// the Microsoft sign-in that replaced it (favorites, links, notifications). Nil when it no longer exists.
    func resolvedRole(id: String) -> EligibleRole? {
        guard let role = eligibleRole(id: id), let account = role.account else { return nil }
        let supersession = supersession()
        guard supersession.hides(account.id, role.source) else { return role }
        return eligibleRole(id: supersession.resolve(eligibleRoleId: id, source: role.source))
    }

    /// The role a favorite item activates (see `resolvedRole`): the confirmation and the run read the same one.
    func favoriteRole(for item: FavoriteItem) -> EligibleRole? {
        resolvedRole(id: item.eligibleRoleId)
    }

    /// PIM sources of one account, acting only with a token of that account's own identity.
    func sources(for account: Account) throws -> [any PIMSource] {
        let provider = try tokenProvider(account)
        let tenantId = account.tenantId, objectId = account.objectId.lowercased(), upn = account.upn, mode = account.mode
        return makeSources(account, { resource, claims in
            let token = try await provider.token(for: resource, tenantId: tenantId, claims: claims)
            // `az` follows whoever last ran `az login`: never act for one account with another identity's token.
            // Fails closed: a token without readable `oid` and `tid` is refused too (security review, low 1).
            let jwt = JWTClaims(token: token.value)
            guard jwt?.objectId?.lowercased() == objectId, jwt?.tenantId?.lowercased() == tenantId.lowercased() else {
                throw mode == .azureCLI ? TokenError.cliNotSignedIn(command: "az login --tenant \(tenantId)  # as \(upn)")
                    : TokenError.failed("Microsoft returned a token for another identity than \(upn). Sign in again.")
            }
            return token
        }, account.directoryAccess == .enabled)
    }
}
