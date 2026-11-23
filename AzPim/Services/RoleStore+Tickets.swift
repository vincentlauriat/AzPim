import AzPimCore
import Foundation
import SwiftData

/// Where ticket fields are remembered: the ticket system per tenant, the last ticket number per role.
struct TicketMemory {
    var loadSystems: () -> [String: String]
    var saveSystems: ([String: String]) -> Void
    var loadNumbers: () -> [String: TicketRecall.Entry]
    var saveNumbers: ([String: TicketRecall.Entry]) -> Void

    /// The preferences, under `PreferenceKeys.ticketSystems` and `PreferenceKeys.lastTickets`. Values of another type
    /// are ignored.
    static func defaults(_ defaults: UserDefaults) -> TicketMemory {
        TicketMemory(loadSystems: { defaults.dictionary(forKey: PreferenceKeys.ticketSystems)?.compactMapValues { $0 as? String } ?? [:] },
                     saveSystems: { defaults.set($0, forKey: PreferenceKeys.ticketSystems) },
                     loadNumbers: { TicketRecall.decode(defaults.dictionary(forKey: PreferenceKeys.lastTickets)) },
                     saveNumbers: { defaults.set(TicketRecall.encode($0), forKey: PreferenceKeys.lastTickets) })
    }

    /// Nothing written to disk (tests, snapshots).
    static func inMemory() -> TicketMemory {
        final class Box {
            var systems: [String: String] = [:]
            var numbers: [String: TicketRecall.Entry] = [:]
        }
        let box = Box()
        return TicketMemory(loadSystems: { box.systems }, saveSystems: { box.systems = $0 },
                            loadNumbers: { box.numbers }, saveNumbers: { box.numbers = $0 })
    }
}

/// Ticket fields (1.0 item 7): prefilled in the Activation Sheet and the grouped favorite sheet only, never sent by a
/// quick activation, a link or Shortcuts on their own.
extension RoleStore {
    /// Ticket system last used in the role's tenant, else empty.
    func ticketSystem(for role: EligibleRole) -> String {
        guard let tenant = role.account?.tenantId else { return "" }
        return ticketMemory.loadSystems()[TicketRecall.tenantKey(tenant)] ?? ""
    }

    /// Ticket number last used for one of these roles within 8 hours (same incident), else empty.
    func recentTicket(for roles: [EligibleRole], now: Date = .now) -> String {
        let numbers = ticketMemory.loadNumbers()
        return TicketRecall.prefill(roles.map { Self.ticketKey($0).flatMap { numbers[$0] } }, now: now)
    }

    /// After Azure accepted a request with a ticket: its system for the tenant, its number for the role.
    func rememberTicket(_ input: ActivationInput, for role: EligibleRole, at now: Date = .now) {
        guard let info = input.ticketInfo, let number = info["ticketNumber"] else { return }
        if let system = info["ticketSystem"], let tenant = role.account?.tenantId {
            var systems = ticketMemory.loadSystems()
            systems[TicketRecall.tenantKey(tenant)] = system
            ticketMemory.saveSystems(systems)
        }
        guard let key = Self.ticketKey(role) else { return }
        var numbers = ticketMemory.loadNumbers()
        numbers[key] = TicketRecall.Entry(number: number, usedAt: now)
        ticketMemory.saveNumbers(numbers)
    }

    /// Keeps the systems of tenants still signed in, and the recent numbers of roles still cached (with the durations).
    func pruneTickets(now: Date = .now) {
        let systems = ticketMemory.loadSystems(), numbers = ticketMemory.loadNumbers()
        guard !systems.isEmpty || !numbers.isEmpty else { return }
        let tenants = Set(((try? context.fetch(FetchDescriptor<Account>())) ?? []).map { TicketRecall.tenantKey($0.tenantId) })
        let keptSystems = systems.filter { tenants.contains($0.key) }
        if keptSystems.count != systems.count { ticketMemory.saveSystems(keptSystems) }
        let roles = (try? context.fetch(FetchDescriptor<EligibleRole>())) ?? []
        let keptNumbers = TicketRecall.pruned(numbers, keeping: Set(roles.compactMap(Self.ticketKey)), now: now)
        if keptNumbers.count != numbers.count { ticketMemory.saveNumbers(keptNumbers) }
    }

    /// Same key as the remembered duration: survives refreshes and the Azure CLI → Microsoft sign-in supersede.
    private static func ticketKey(_ role: EligibleRole) -> String? {
        guard let account = role.account, !account.isDeleted else { return nil }
        return ActivationDuration.roleKey(identity: account.identity, source: role.source,
                                          roleDefinitionId: role.roleDefinitionId, roleName: role.roleName, scope: role.scope)
    }

    // MARK: - Favorites

    /// Roles of a favorite a run would send (not active, not already waiting), with their policy read first.
    func favoriteRolesToSend(_ favorite: Favorite) async -> [(item: FavoriteItem, role: EligibleRole)] {
        let active = Set(activeActivations().compactMap { $0.eligibleRole?.id })
        var roles: [(item: FavoriteItem, role: EligibleRole)] = []
        for item in favorite.items {
            guard let role = favoriteRole(for: item), !active.contains(role.id), waitingRequest(for: role) == nil else { continue }
            await ensurePolicy(for: role)
            roles.append((item, role))
        }
        return roles
    }

    /// What the grouped favorite sheet must ask before `run` can send every role (nothing: run it at once).
    func favoriteNeeds(_ favorite: Favorite) async -> FavoriteNeeds {
        FavoriteRun.needs(await favoriteRolesToSend(favorite).map {
            FavoriteRun.Pending(item: $0.item, policy: $0.role.policy, lastJustification: $0.role.lastJustification)
        })
    }
}
