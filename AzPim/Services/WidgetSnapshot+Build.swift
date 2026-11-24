import AzPimCore
import Foundation
import SwiftData

extension RoleStore {
    /// The widgets' snapshot: the activations and permanent assignments the panel shows (one account per identity,
    /// one row per role, superseded accounts left out), the activation ending first on top, then the favorites.
    func widgetSnapshot(now: Date = .now) -> WidgetSnapshot {
        let accountList = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let assignments = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        let favorites = (try? context.fetch(FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let supersession = supersession(accountList)
        let model = PanelModel(accounts: accountList.filter { !supersession.isRetired($0.id) }, assignments: assignments,
                               supersession: supersession, now: now)
        let roles = (model.activations + model.permanents).map { row in
            let assignment = row.assignment
            let timed = assignment.assignmentType == .activated
            return WidgetSnapshot.Role(id: assignment.id, name: assignment.displayRoleName,
                                       scope: assignment.displayScopeName, symbol: SourceIcon.name(assignment.source),
                                       startAt: timed ? assignment.startAt : nil, endAt: timed ? assignment.endAt : nil)
        }
        return WidgetSnapshot(generatedAt: now, roles: roles, favorites: favorites.map {
            WidgetSnapshot.Favorite(id: $0.id, name: $0.name, roleCount: $0.items.count)
        })
    }
}
