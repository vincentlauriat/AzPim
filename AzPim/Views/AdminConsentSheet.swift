import AppKit
import AzPimCore
import SwiftData
import SwiftUI

/// Admin Consent Sheet (AppFlow, ImplementationPlan T3.8): explains the missing consent, builds the consent link
/// and a ready-to-send email (templates in docs/admin-consent/).
struct AdminConsentSheet: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    let accountId: UUID?
    @Query private var allAccounts: [Account]
    @State private var status: String?
    @State private var checking = false

    private var account: Account? { allAccounts.first { $0.id == accountId } }

    var body: some View {
        Group {
            if let account {
                content(account)
            } else {
                ContentUnavailableView("Account not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .frame(width: 560)
        .padding(20)
    }

    private func content(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Admin consent required", systemImage: "info.circle").font(.title3.weight(.semibold))
            Text("""
            Microsoft Graph only lets AzPim read and activate Entra roles and PIM groups after an administrator \
            of \(account.tenantName ?? account.tenantId) consents to these delegated permissions. Azure resource roles \
            keep working meanwhile.
            """)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(ConsentRequest.permissions, id: \.0) { permission, purpose in
                    HStack(alignment: .firstTextBaseline) {
                        Text(permission).font(.caption.monospaced())
                        Text("— \(purpose)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let link = ConsentRequest.link(tenantId: account.tenantId, clientId: account.msalClientId ?? accounts.msalClientId) {
                Text(link.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button("Copy consent link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        status = String(localized: "Link copied.")
                    }
                    Button("Prepare email") {
                        if let mail = ConsentRequest.mailto(account: account, link: link) { NSWorkspace.shared.open(mail) }
                    }
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check again") { Task { await check(account) } }
                        .disabled(checking)
                }
            } else {
                Text("Microsoft sign-in is not configured in this build (no client ID), so no consent link can be built.")
                    .foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func check(_ account: Account) async {
        checking = true
        defer { checking = false }
        do {
            try await accounts.enableDirectoryAccess(for: account)
            if account.directoryAccess == .enabled {
                status = String(localized: "Consent granted — loading Entra roles.")
                await store.refresh()
                dismissWindow()
            } else {
                status = String(localized: "Still waiting for admin consent.")
            }
        } catch {
            status = AccountService.message(for: error)
        }
    }
}

enum ConsentRequest {
    static var permissions: [(String, String)] { [
        ("User.Read", String(localized: "identify the signed-in user")),
        ("RoleEligibilitySchedule.Read.Directory", String(localized: "list eligible Entra roles")),
        ("RoleAssignmentSchedule.ReadWrite.Directory", String(localized: "activate / deactivate your own Entra roles")),
        ("RoleManagementPolicy.Read.Directory", String(localized: "read PIM rules")),
        ("PrivilegedEligibilitySchedule.Read.AzureADGroup", String(localized: "list eligible PIM groups")),
        ("PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup", String(localized: "activate your own PIM group membership")),
        ("RoleManagementPolicy.Read.AzureADGroup", String(localized: "read PIM group rules"))
    ] }

    static func link(tenantId: String, clientId: String?) -> URL? {
        guard let clientId else { return nil }
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenantId)/v2.0/adminconsent")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: "https://graph.microsoft.com/.default"),
            URLQueryItem(name: "redirect_uri", value: "msauth.\(Bundle.main.bundleIdentifier ?? "fr.vincentlauriat.azpim")://auth")
        ]
        return components.url
    }

    /// `mailto:` draft based on docs/admin-consent/email-template-tenant-admin.md, in the language the app shows.
    static func mailto(account: Account, link: URL) -> URL? {
        let french = Bundle.main.preferredLocalizations.first == "fr"
        let separator = french ? "\u{00A0}: " : ": "
        let list = permissions.map { "- \($0.0)\(separator)\($0.1)" }.joined(separator: "\n")
        let tenant = account.tenantName ?? account.tenantId
        let subject = french ? "Demande de consentement administrateur – AzPim (activation PIM)"
                             : "Admin consent request — AzPim (self-service PIM activation)"
        let body = french ? """
        Bonjour,

        J’utilise AzPim, une application macOS gratuite pour activer, suivre et terminer mes propres rôles PIM. \
        Pour les rôles Microsoft Entra et les groupes PIM, Microsoft Graph exige un consentement administrateur.

        Pourriez-vous accorder ce consentement pour le locataire \(tenant)\u{00A0}?
        \(link.absoluteString)

        Autorisations déléguées uniquement (l’application agit au nom de l’utilisateur, avec ses propres droits)\u{00A0}:
        \(list)

        Les règles PIM (MFA, justification, ticket, approbation, durée maximale) restent appliquées par Microsoft. \
        Aucun serveur, aucune télémétrie.

        Merci,
        \(account.upn)
        """ : """
        Hello,

        I use AzPim, a free macOS app to activate, track and end my own PIM roles. For Entra roles and PIM \
        groups, Microsoft Graph requires admin consent.

        Could you grant consent for tenant \(tenant)?
        \(link.absoluteString)

        Delegated permissions only (the app acts as the signed-in user, within that user's own rights):
        \(list)

        PIM policies (MFA, justification, ticket, approval, maximum duration) stay enforced by Microsoft. \
        No server, no telemetry.

        Thank you,
        \(account.upn)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}
