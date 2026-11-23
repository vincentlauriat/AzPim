import Foundation

/// Time left read by VoiceOver, in words: « 3 hours, 15 minutes » / « 3 heures et 15 minutes ». Rounded down to the
/// minute, so a focused countdown is not read again every second; « less than a minute » in the last one.
public enum SpokenDuration {
    /// `locale` nil: the app's language (`AppLanguage`).
    public static func text(_ seconds: TimeInterval, locale: Locale? = nil) -> String {
        let minutes = max(0, Int(seconds)) / 60
        guard minutes > 0 else { return L10n.string("less than a minute", locale: locale) }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale ?? AppLanguage.locale))
    }
}

/// What a role row is, for its spoken label.
public enum SpokenRoleState: Equatable, Sendable {
    case eligible
    /// Activated; `remaining` nil when the activation has no end.
    case active(remaining: TimeInterval?)
    case pendingApproval
    /// Sent, not confirmed by Azure yet.
    case sent
    case permanent
    /// A request (activation, Extend, deactivation) is running for the row.
    case busy
}

/// The single VoiceOver label of a role row (panel, palette): role, type, scope, state and time left in words.
/// « Contributor, Azure role, rg-app-prod, active, 3 hours, 15 minutes left ». `account`: the tenant or account the
/// row shows beside the scope; `error`: the row's error line, read with it.
public enum SpokenRole {
    public static func label(role: String, source: RoleSource, scope: String?, state: SpokenRoleState,
                             viaGroup: Bool = false, alsoPermanent: Bool = false, account: String? = nil,
                             error: String? = nil, locale: Locale? = nil) -> String {
        var parts = [role, typeName(source, locale: locale)]
        if let scope, !scope.isEmpty { parts.append(scope) }
        if viaGroup { parts.append(L10n.string("via group", locale: locale)) }
        if let account, !account.isEmpty { parts.append(account) }
        parts.append(contentsOf: stateWords(state, locale: locale))
        if alsoPermanent { parts.append(L10n.string("also permanent", locale: locale)) }
        if let error, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: ", ")
    }

    /// « Azure role » / « rôle Azure ».
    public static func typeName(_ source: RoleSource, locale: Locale? = nil) -> String {
        switch source {
        case .azureResource: L10n.string("Azure role", locale: locale)
        case .entraRole: L10n.string("Entra role", locale: locale)
        case .pimGroup: L10n.string("PIM group", locale: locale)
        }
    }

    private static func stateWords(_ state: SpokenRoleState, locale: Locale?) -> [String] {
        switch state {
        case .eligible: return [L10n.string("eligible", locale: locale)]
        case .active(let remaining):
            let active = L10n.string("active", locale: locale)
            guard let remaining else { return [active] }
            let left = SpokenDuration.text(remaining, locale: locale)
            return [active, L10n.string("\(left) left", locale: locale)]
        case .pendingApproval: return [L10n.string("pending approval", locale: locale)]
        case .sent: return [L10n.string("request sent, not confirmed yet", locale: locale)]
        case .permanent: return [L10n.string("permanent", locale: locale)]
        case .busy: return [L10n.string("request in progress", locale: locale)]
        }
    }
}
