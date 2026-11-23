import AzPimCore
import Foundation

/// Names the core writes as data when Azure gives none: « Directory » for the tenant-wide scope of an Entra role,
/// « Owner » / « Member » for a PIM group role. Translated when shown only: the store, the dedup keys, the search on
/// raw names and the CSV keep the English data.
enum DisplayName {
    static func role(_ name: String, source: RoleSource) -> String {
        guard source == .pimGroup else { return name }
        switch name {
        case "Owner": return String(localized: "Owner")
        case "Member": return String(localized: "Member")
        default: return name
        }
    }

    static func scope(_ name: String, source: RoleSource) -> String {
        source == .entraRole && name == "Directory" ? String(localized: "Directory") : name
    }
}

extension Date {
    /// `formatted(date:time:)` in the app's language (`AppLanguage`), with the user's region.
    func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(AppLanguage.locale))
    }
}

extension EligibleRole {
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
}

extension ActiveAssignment {
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
}

extension ActivationRecord {
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
}

extension RemoteRequest {
    var displayRoleName: String { DisplayName.role(roleName, source: source) }
    var displayScopeName: String { DisplayName.scope(scopeName, source: source) }
}
