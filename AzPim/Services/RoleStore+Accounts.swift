import AzPimCore
import Foundation
import SwiftData

/// One account per identity: what the store reads and acts on leaves out a superseded Azure CLI account.
extension RoleStore {
    /// Live activations of the accounts in use (never those of a superseded account): notifications, Extend, favorites.
    func activeActivations() -> [ActiveAssignment] {
        let all = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        let superseded = supersededAccounts()
        return all.filter {
            $0.assignmentType == .activated && $0.isLive() && $0.account.map { superseded[$0.id] == nil } == true
        }
    }

    /// Azure CLI accounts replaced by a Microsoft sign-in of the same identity: `[CLI id: MSAL id]`.
    func supersededAccounts() -> [UUID: UUID] {
        AccountSupersede.superseded(((try? context.fetch(FetchDescriptor<Account>())) ?? []).map(\.facts))
    }

    /// PIM sources of one account, acting only with a token of that account's own identity.
    func sources(for account: Account) throws -> [any PIMSource] {
        let provider = try accounts.provider(for: account)
        let tenantId = account.tenantId, objectId = account.objectId.lowercased(), upn = account.upn, mode = account.mode
        return PIMService.sources(token: { resource, claims in
            let token = try await provider.token(for: resource, tenantId: tenantId, claims: claims)
            // `az` follows whoever last ran `az login`: never act for one account with another identity's token.
            // Fails closed: a token without readable `oid` and `tid` is refused too (security review, low 1).
            let jwt = JWTClaims(token: token.value)
            guard jwt?.objectId?.lowercased() == objectId, jwt?.tenantId?.lowercased() == tenantId.lowercased() else {
                throw mode == .azureCLI ? TokenError.cliNotSignedIn(command: "az login --tenant \(tenantId)  # as \(upn)")
                    : TokenError.failed("Microsoft returned a token for another identity than \(upn). Sign in again.")
            }
            return token
        }, directory: account.directoryAccess == .enabled)
    }
}
