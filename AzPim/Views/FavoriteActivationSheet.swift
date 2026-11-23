import AzPimCore
import SwiftUI

/// A favorite and the roles a run would send, read once before the grouped sheet opens.
struct FavoriteRunRequest: Identifiable {
    let favorite: Favorite
    /// Not active, not already waiting, policy read (`RoleStore.favoriteRolesToSend`).
    let roles: [(item: FavoriteItem, role: EligibleRole)]

    var id: UUID { favorite.id }
}

/// Grouped favorite sheet (1.0 item 7): a favorite with a role that needs a ticket, or a justification it does not
/// have, asks once for the justification and the tickets, then activates every role of the favorite with them. A typed
/// justification replaces the one of every role; a ticket goes to the roles of its tenant that require one, one ticket
/// per tenant. Prefilled like the Activation Sheet when every ticket role is in one tenant.
struct FavoriteActivationSheet: View {
    @Environment(RoleStore.self) private var store
    let request: FavoriteRunRequest
    /// False outside the menu bar panel: keeps the records out of the time-to-activation median.
    var fromPanel = true
    let close: () -> Void

    @State private var justification = ""
    @State private var tickets: [String: FavoriteAnswers.Ticket] = [:]
    @State private var sending = false
    @FocusState private var focused: Bool

    private var roles: [EligibleRole] { request.roles.map(\.role) }
    private var needs: FavoriteNeeds { store.favoriteNeeds(request.roles) }
    private var answers: FavoriteAnswers { FavoriteAnswers(justification: justification, tickets: tickets) }
    /// The favorite spans several tenants: each role line names its tenant (same tenant key as the tickets).
    private var spansTenants: Bool {
        Set(roles.compactMap { $0.account.map { TicketRecall.tenantKey($0.tenantId) } }).count > 1
    }

    private var block: ActivationBlock? {
        if store.isOffline { return .offline }
        return FavoriteRun.block(needs, answers: answers)
    }

    var body: some View {
        let block = self.block, needs = self.needs
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activate \(request.favorite.name)").font(.headline)
                Text("\(roles.count) roles").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                let spansTenants = self.spansTenants
                ForEach(roles) { role in
                    HStack(spacing: 6) {
                        Text(roleLine(role, tenant: spansTenants))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if role.requiresTicket {
                            Text("Ticket required").font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Justification", text: $justification,
                          prompt: Text(needs.justification ? "Why do you need these roles?" : "Leave empty to keep each role’s own"),
                          axis: .vertical)
                    .lineLimit(2...4)
                    .focused($focused)
                // Said whether the field is empty or not: what is typed here wins over each role's own.
                if needs.replacesJustification {
                    Text("Replaces each role’s justification.").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(needs.ticketTenants, id: \.self) { tenant in
                TicketFields(system: field(tenant, \.system), number: field(tenant, \.number),
                             tenant: needs.ticketTenants.count > 1 ? tenantName(tenant) : nil)
            }

            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button("Activate") { Task { await send() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accentFill)
                        .keyboardShortcut(.defaultAction)
                        .disabled(block != nil || sending)
                }
                if !sending, let block {
                    Text(block.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .task {
            tickets = store.favoriteTicketPrefill(roles, needs: needs)
            focused = true
        }
    }

    private func field(_ tenant: String, _ path: WritableKeyPath<FavoriteAnswers.Ticket, String>) -> Binding<String> {
        Binding(get: { tickets[tenant, default: FavoriteAnswers.Ticket()][keyPath: path] },
                set: { tickets[tenant, default: FavoriteAnswers.Ticket()][keyPath: path] = $0 })
    }

    /// « Security Reader — Directory », plus « · Contoso » when the favorite spans tenants.
    private func roleLine(_ role: EligibleRole, tenant: Bool) -> String {
        let line = "\(role.displayRoleName) — \(role.displayScopeName)"
        guard tenant, let account = role.account else { return line }
        return "\(line) · \(account.tenantName ?? account.tenantId)"
    }

    /// The tenant's display name, from one of its roles' accounts.
    private func tenantName(_ tenant: String) -> String {
        let account = roles.compactMap(\.account).first { TicketRecall.tenantKey($0.tenantId) == tenant }
        return account.map { $0.tenantName ?? $0.tenantId } ?? tenant
    }

    private func send() async {
        sending = true
        defer { sending = false }
        // The result is notified, and shows as the favorite's toast in the panel and in the Favorites editor.
        await store.run(request.favorite, fromPanel: fromPanel, answers: answers, announce: true)
        close()
    }
}
