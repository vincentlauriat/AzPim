import Foundation

/// Validation rules of BackendSchema › Data validation.
public enum Validation {
    public enum Failure: Error, Equatable, Sendable {
        case empty(String)
        case tooLong(String, max: Int)
        case outOfRange(String, ClosedRange<Int>)
        case invalidFormat(String)
        case duplicate(String)
        case exceedsPolicy(max: TimeInterval)
    }

    public static func favoriteName(_ raw: String, existing: [String]) -> Result<String, Failure> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty("name")) }
        guard name.count <= 40 else { return .failure(.tooLong("name", max: 40)) }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .failure(.duplicate("name"))
        }
        return .success(name)
    }

    public static func justification(_ text: String, required: Bool) -> Failure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { return .empty("justification") }
        if trimmed.count > 500 { return .tooLong("justification", max: 500) }
        return nil
    }

    public static func ticketNumber(_ text: String, required: Bool) -> Failure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { return .empty("ticket") }
        if trimmed.count > 100 { return .tooLong("ticket", max: 100) }
        return nil
    }

    /// Longest activation Azure PIM accepts at all, whatever the policy: the hard ceiling of `duration` when the policy
    /// is unknown. Not the app's own default cap for an unknown policy (`ActivationDuration.unknownPolicyMaxMinutes`,
    /// 8 h), which keeps the durations the app proposes well under it.
    public static let azureMaxActivation: TimeInterval = 24 * 3600

    /// Validates an activation duration: 5 min ≤ d ≤ policy max (`azureMaxActivation` when unknown).
    public static func duration(_ iso: String, policyMax: String?) -> Result<TimeInterval, Failure> {
        guard let seconds = ISODuration.seconds(iso) else { return .failure(.invalidFormat("duration")) }
        let cap = policyMax.flatMap(ISODuration.seconds) ?? azureMaxActivation
        guard seconds >= 5 * 60 else { return .failure(.outOfRange("duration", 5...Int(cap / 60))) }
        guard seconds <= cap else { return .failure(.exceedsPolicy(max: cap)) }
        return .success(seconds)
    }

    public static func setting(_ name: String, _ value: Int) -> Failure? {
        let range: ClosedRange<Int>
        switch name {
        case "refreshIntervalMinutes": range = 1...30
        case "notificationLeadMinutes": range = 5...60
        case "historyRetentionDays": range = 7...365
        default: return nil
        }
        return range.contains(value) ? nil : .outOfRange(name, range)
    }

    public static func clientId(_ text: String) -> Failure? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) == nil ? .invalidFormat("clientId") : nil
    }

    /// `azCLIPath` must be an executable file named `az`.
    public static func azPath(_ path: String, fileManager: FileManager = .default) -> Failure? {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == "az", fileManager.isExecutableFile(atPath: path) else {
            return .invalidFormat("azCLIPath")
        }
        // Both the link and its resolved target, with every ancestor folder, must be owned by root or the user and not
        // writable by others (security review L2). The resolved target is what gets executed (`locateCLI`).
        let target = url.resolvingSymlinksInPath()
        for start in [url, target] where !isTrustedChain(start, fileManager: fileManager) {
            return .invalidFormat("azCLIPath")
        }
        return nil
    }

    /// The configured `az`, resolved once: the returned path is the exact string that was validated and that runs.
    public static func trustedAZ(_ path: String, fileManager: FileManager = .default) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard azPath(path, fileManager: fileManager) == nil,
              resolved == URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path,
              isTrustedChain(URL(fileURLWithPath: resolved), fileManager: fileManager) else { return nil }
        return resolved
    }

    /// The item and all its ancestors: readable attributes, owner root or current user, not world-writable, and
    /// group-writable only for wheel (0) or admin (80) — admins can already act as root; Homebrew's prefix is
    /// admin-writable. Root-owned sticky folders (/tmp) are tolerated as distant ancestors only, never as the
    /// executable's own folder. Extended ACLs are not inspected (accepted risk, TRD › Security).
    static func isTrustedChain(_ url: URL, fileManager: FileManager) -> Bool {
        var item = url.standardizedFileURL
        var depth = 0
        while true {
            guard let attributes = try? fileManager.attributesOfItem(atPath: item.path),
                  let mode = attributes[.posixPermissions] as? Int,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value else { return false }
            guard owner == 0 || owner == getuid() else { return false }
            if mode & 0o020 != 0 && group != 0 && group != 80 { return false }
            let stickyRoot = mode & 0o1000 != 0 && owner == 0 && depth >= 2
            if mode & 0o002 != 0 && !stickyRoot { return false }
            if item.path == "/" { return true }
            item = item.deletingLastPathComponent()
            depth += 1
        }
    }
}

/// Minimal ISO 8601 duration support for PIM: `PT<n>H<n>M<n>S` and `P<n>D`.
public enum ISODuration {
    public static func seconds(_ iso: String) -> TimeInterval? {
        let pattern = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/
        guard iso != "P", iso != "PT", let match = iso.wholeMatch(of: pattern) else { return nil }
        let days = Double(match.1 ?? "0") ?? 0
        let hours = Double(match.2 ?? "0") ?? 0
        let minutes = Double(match.3 ?? "0") ?? 0
        let secs = Double(match.4 ?? "0") ?? 0
        let total = days * 86400 + hours * 3600 + minutes * 60 + secs
        return total > 0 ? total : nil
    }

    public static func string(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        switch (hours, minutes) {
        case (0, let mins): return "PT\(mins)M"
        case (let hrs, 0): return "PT\(hrs)H"
        case (let hrs, let mins): return "PT\(hrs)H\(mins)M"
        }
    }

    /// Short label for a duration, rounded to the minute, by the system formatter: « 45 min », « 2 hr », « 1 hr 30 min »
    /// in English, « 1 h 30 min » in French (never « 0 h » for a policy under one hour). `locale` nil: the system's.
    public static func label(_ seconds: TimeInterval, locale: Locale? = nil) -> String {
        Duration.seconds(Int((seconds / 60).rounded()) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .condensedAbbreviated).locale(locale ?? .current))
    }
}

extension Validation.Failure {
    /// Short message for inline errors and toasts, in the system language.
    public var userMessage: String { userMessage(locale: nil) }

    public func userMessage(locale: Locale?) -> String {
        switch self {
        case .empty("name"): L10n.string("Name required", locale: locale)
        case .empty("justification"): L10n.string("Justification required", locale: locale)
        case .empty("ticket"): L10n.string("Ticket number required by policy", locale: locale)
        case .empty(let field): L10n.string("\(Self.fieldName(field, locale: locale)) required", locale: locale)
        case .tooLong(let field, let max):
            L10n.string("\(Self.fieldName(field, locale: locale)) is limited to \(max) characters", locale: locale)
        case .outOfRange(let field, let range):
            L10n.string("\(Self.fieldName(field, locale: locale)) must be between \(range.lowerBound) and \(range.upperBound)",
                        locale: locale)
        case .invalidFormat(let field): L10n.string("Invalid \(Self.fieldName(field, locale: locale))", locale: locale)
        case .duplicate("name"): L10n.string("This name is already used", locale: locale)
        case .duplicate(let field): L10n.string("Already used: \(Self.fieldName(field, locale: locale))", locale: locale)
        case .exceedsPolicy(let max):
            L10n.string("Longer than the policy maximum (\(ISODuration.label(max, locale: locale)))", locale: locale)
        }
    }

    /// Name of a validated field, as the messages show it.
    static func fieldName(_ field: String, locale: Locale?) -> String {
        switch field {
        case "name": L10n.string("Name", locale: locale)
        case "justification": L10n.string("Justification", locale: locale)
        case "ticket": L10n.string("Ticket number", locale: locale)
        case "duration": L10n.string("Duration", locale: locale)
        case "clientId": L10n.string("Client ID", locale: locale)
        case "azCLIPath": L10n.string("Azure CLI path", locale: locale)
        case "refreshIntervalMinutes": L10n.string("Refresh interval", locale: locale)
        case "notificationLeadMinutes": L10n.string("Notification lead time", locale: locale)
        case "historyRetentionDays": L10n.string("History retention", locale: locale)
        default: field
        }
    }
}
