import AzPimCore
import SwiftUI

/// Grouped favorite sheet (1.0 item 7): a favorite with a role that needs a ticket, or a justification it does not
/// have, asks once for the justification and the ticket, then activates every role of the favorite with them. A typed
/// justification goes to every role; the ticket to the roles that require one. Same prefill as the Activation Sheet.
struct FavoriteActivationSheet: View {
    @Environment(RoleStore.self) private var store
    let favorite: Favorite
    /// False outside the menu bar panel: keeps the records out of the time-to-activation median.
    var fromPanel = true
    let close: () -> Void

    /// Roles the run would send (not active, not already waiting); nil until read.
    @State private var roles: [EligibleRole]?
    @State private var needs = FavoriteNeeds()
    @State private var justification = ""
    @State private var ticketSystem = ""
    @State private var ticket = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var answers: FavoriteAnswers {
        FavoriteAnswers(justification: justification, ticketSystem: ticketSystem, ticketNumber: ticket)
    }

    private var block: ActivationBlock? {
        if store.isOffline { return .offline }
        return FavoriteRun.block(needs, answers: answers)
    }

    var body: some View {
        let block = self.block
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activate \(favorite.name)").font(.headline)
                Text("\(favorite.items.count) roles").font(.caption).foregroundStyle(.secondary)
            }

            if let roles {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(roles) { role in
                        HStack(spacing: 6) {
                            Text("\(role.displayRoleName) — \(role.displayScopeName)")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if role.requiresTicket {
                                Text("Ticket required").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                    }
                }
            }

            TextField("Justification", text: $justification,
                      prompt: Text(needs.justification ? "Why do you need these roles?" : "Leave empty to keep each role’s own"),
                      axis: .vertical)
                .lineLimit(2...4)
                .focused($focused)

            if needs.ticket {
                TicketFields(system: $ticketSystem, number: $ticket)
            }

            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button("Activate") { Task { await send() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(block != nil || sending || roles == nil)
                }
                if !sending, let block {
                    Text(block.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .task {
            let pending = await store.favoriteRolesToSend(favorite)
            needs = FavoriteRun.needs(pending.map {
                FavoriteRun.Pending(item: $0.item, policy: $0.role.policy, lastJustification: $0.role.lastJustification)
            })
            let ticketRoles = pending.map(\.role).filter(\.requiresTicket)
            ticketSystem = ticketRoles.first.map { store.ticketSystem(for: $0) } ?? ""
            ticket = store.recentTicket(for: ticketRoles)
            roles = pending.map(\.role)
            focused = true
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        // The result shows as the favorite's toast, in the panel and in the Favorites editor.
        await store.run(favorite, fromPanel: fromPanel, answers: answers)
        close()
    }
}
