import AzPimCore
import SwiftUI

/// Activation Sheet (AppFlow): duration in 15-minute steps capped by policy (the last one used for the role, else 1 h),
/// justification / ticket validation, send; when Activate is disabled, the reason is shown under it. The ticket system
/// is prefilled from the tenant's last one, the ticket number from the role's last one if used within 8 hours.
/// Shown inside the menu bar panel so the panel stays open while the user types.
struct ActivationSheet: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    /// False outside the menu bar panel (Roles Window): keeps the record out of the time-to-activation median.
    var fromPanel = true
    let close: () -> Void

    @State private var minutes = ActivationDuration.fallbackMinutes
    @State private var justification = ""
    @State private var ticketSystem = ""
    @State private var ticket = ""
    @State private var result: RequestStatus?
    /// This sheet's own request is running: the busy state is not shown as a reason.
    @State private var sending = false
    /// The user changed the duration: a policy read afterwards no longer resets it.
    @State private var durationTouched = false
    @FocusState private var focused: Bool

    private var duration: String { ActivationDuration.iso(minutes) }

    /// Why Activate is disabled, nil when the request can be sent. Read once per body; `store.now` makes the body
    /// follow the store clock, so a sent request stops blocking once its 15-minute window is over.
    private var block: ActivationBlock? {
        ActivationBlock.reason(.init(inProgress: store.busy.contains(role.id),
                                     pending: store.waitingRequest(for: role, at: store.now) != nil,
                                     offline: store.isOffline, minutes: minutes, policyMax: role.maxDuration,
                                     requiresJustification: role.requiresJustification, justification: justification,
                                     requiresTicket: role.requiresTicket, ticketSystem: ticketSystem, ticket: ticket))
    }

    var body: some View {
        let block = self.block
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activate \(role.displayRoleName)").font(.headline)
                Text(role.displayScopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(policyHint).font(.caption).foregroundStyle(.secondary)
            }

            DurationPicker(minutes: Binding(get: { minutes }, set: { minutes = $0; durationTouched = true }),
                           policyMax: role.maxDuration)

            TextField("Justification", text: $justification, prompt: Text("Why do you need this role?"), axis: .vertical)
                .lineLimit(2...4)
                .focused($focused)

            if role.requiresTicket {
                TicketFields(system: $ticketSystem, number: $ticket)
            }

            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if result == .pendingApproval {
                Label("Request sent — pending approval.", systemImage: "clock").font(.caption).foregroundStyle(.orange)
            } else if result != nil {
                // Accepted but not confirmed yet (or already decided): sending it again would submit a second request.
                Label("Request sent — not confirmed yet. Check the panel in a moment.", systemImage: "paperplane")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if store.busy.contains(role.id) { ProgressView().controlSize(.small) }
                    // A request Azure accepted (any result) is never sent twice from the same sheet: the button becomes Done.
                    Button(result != nil ? "Done" : "Activate") {
                        if result != nil { close() } else { Task { await send() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil && block != nil)
                }
                // One sentence under the button: why it cannot be pressed (not while this sheet's own request runs).
                if result == nil, !sending, let block {
                    Text(block.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .announcesChanges(store.rowErrors[role.id])
        .task {
            justification = role.lastJustification ?? ""
            ticketSystem = store.ticketSystem(for: role)
            ticket = store.recentTicket(for: [role])
            // Shown at once from the cached policy; read again once the policy is known, unless already changed.
            minutes = store.defaultDurationMinutes(for: role)
            await store.ensurePolicy(for: role)
            if !durationTouched { minutes = store.defaultDurationMinutes(for: role) }
            focused = true
        }
    }

    private var policyHint: String {
        let max = ISODuration.label(TimeInterval(ActivationDuration.maxMinutes(policyMax: role.maxDuration) * 60))
        var parts = [String(localized: "Max \(max)")]
        if role.requiresTicket { parts.append(String(localized: "Ticket required")) }
        if role.requiresMFA { parts.append(String(localized: "MFA required")) }
        if role.requiresApproval { parts.append(String(localized: "Approval required")) }
        return parts.joined(separator: " · ")
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let input = ActivationInput(duration: duration, justification: justification.trimmingCharacters(in: .whitespacesAndNewlines),
                                    ticketNumber: role.requiresTicket ? ticket.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                                    ticketSystem: role.requiresTicket ? ticketSystem.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        result = await store.activate(role, input: input, fromPanel: fromPanel)
        Announcer.post(activation: result, role: role.displayRoleName)
        if result == .provisioned { close() }
    }
}

/// Ticket system and number, side by side under their labels (Activation Sheet, grouped favorite sheet). `tenant`:
/// shown above when the grouped sheet asks one ticket per tenant.
struct TicketFields: View {
    @Binding var system: String
    @Binding var number: String
    var tenant: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tenant { Text(tenant).font(.caption.weight(.semibold)) }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ticket system").font(.caption).foregroundStyle(.secondary)
                    TextField("Ticket system", text: $system, prompt: Text("ServiceNow, Jira…")).labelsHidden()
                }
                .frame(maxWidth: 130)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ticket number").font(.caption).foregroundStyle(.secondary)
                    TextField("Ticket number", text: $number, prompt: Text("INC0012345")).labelsHidden()
                }
            }
        }
    }
}
