import Foundation

/// Keyboard-first activation (1.0 item 3): whether a role may be activated without the Activation Sheet (palette
/// Return, panel Return, ⌥-click), with its default duration.
public enum QuickActivation: Equatable, Sendable {
    /// Send at once: the default duration (last used, else 1 h, capped by the policy) and the last justification.
    case send(ActivationInput)
    /// The policy asks for a justification or a ticket, or is unknown: the sheet collects them, nothing is sent.
    case openSheet
    /// Nothing can be sent now (a request in progress or waiting, offline): the reason, as the sheet shows it.
    case blocked(ActivationBlock)

    public struct Facts: Sendable {
        public var policy: RolePolicy
        /// False while the policy was never read: its defaults (justification required) are not facts.
        public var policyKnown: Bool
        /// Duration last chosen for the role (ISO 8601), if any.
        public var lastDuration: String?
        public var lastJustification: String?
        public var inProgress = false
        public var pending = false
        public var offline = false

        public init(policy: RolePolicy, policyKnown: Bool, lastDuration: String? = nil, lastJustification: String? = nil,
                    inProgress: Bool = false, pending: Bool = false, offline: Bool = false) {
            self.policy = policy
            self.policyKnown = policyKnown
            self.lastDuration = lastDuration
            self.lastJustification = lastJustification
            self.inProgress = inProgress
            self.pending = pending
            self.offline = offline
        }
    }

    /// A policy that requires a justification or a ticket always opens the sheet, even with a justification
    /// remembered: a quick activation never sends a field the user did not see.
    public static func decide(_ facts: Facts) -> QuickActivation {
        let minutes = ActivationDuration.defaultMinutes(lastUsed: facts.lastDuration, policyMax: facts.policy.maxDuration)
        let block = ActivationBlock.reason(.init(inProgress: facts.inProgress, pending: facts.pending, offline: facts.offline,
                                                 minutes: minutes, policyMax: facts.policy.maxDuration,
                                                 requiresJustification: facts.policy.requiresJustification,
                                                 requiresTicket: facts.policy.requiresTicket))
        if let block {
            switch block {
            case .inProgress, .pending, .offline: return .blocked(block)
            // A justification or a ticket required, or a duration only the sheet can fix.
            default: return .openSheet
            }
        }
        guard facts.policyKnown else { return .openSheet }
        // `activate` stores the justification it sends: the last one is kept rather than wiped by an empty one.
        return .send(ActivationInput(duration: ActivationDuration.iso(minutes), justification: facts.lastJustification ?? ""))
    }
}

// MARK: - Palette

/// One row of the quick-activate palette or of the panel's keyboard navigation.
public enum PaletteKind: Sendable, Equatable {
    case eligible
    /// A timed activation: Return extends it, ⌫ deactivates it.
    case active
}

public struct PaletteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PaletteKind
    public let name: String
    public let scope: String
    /// Role type, as the panel names it (« Entra », « Azure roles »…).
    public let types: [String]
    public let tenant: String

    public init(id: String, kind: PaletteKind, name: String, scope: String, types: [String], tenant: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.scope = scope
        self.types = types
        self.tenant = tenant
    }
}

public enum QuickPalette {
    /// The entries matching `query`, best first. Every word must match one field (`RoleSearch`), or the role name as
    /// a subsequence or by initials (« kva » finds Key Vault Administrator). An empty query keeps the given order
    /// (active roles first, as the caller lists them).
    public static func rank(_ query: String, _ entries: [PaletteEntry]) -> [PaletteEntry] {
        guard !RoleSearch.isEmpty(query) else { return entries }
        let scored = entries.enumerated().compactMap { index, entry in
            score(query, entry).map { (entry: entry, score: $0, index: index) }
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.kind != rhs.entry.kind { return lhs.entry.kind == .active }
            return lhs.index < rhs.index
        }.map(\.entry)
    }

    /// Score of one entry, nil when a word matches nothing. Per word: start of the name 100, initials of the name 80,
    /// start of a word of the name 70, inside the name 50, inside another field 30, name as a subsequence 10.
    public static func score(_ query: String, _ entry: PaletteEntry) -> Int? {
        let words = RoleSearch.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let name = RoleSearch.fold(entry.name)
        let nameWords = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let initials = String(nameWords.compactMap(\.first))
        let others = ([entry.scope, entry.tenant] + entry.types).map(RoleSearch.fold)
        var total = 0
        for word in words {
            let best: Int
            if name.hasPrefix(word) {
                best = 100
            } else if word.count > 1, initials.hasPrefix(word) {
                best = 80
            } else if nameWords.contains(where: { $0.hasPrefix(word) }) {
                best = 70
            } else if name.contains(word) {
                best = 50
            } else if others.contains(where: { $0.contains(word) }) {
                best = 30
            } else if isSubsequence(word, of: name) {
                best = 10
            } else {
                return nil
            }
            total += best
        }
        return total
    }

    static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = word[...]
        for character in text where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }

    /// ↑/↓ over `count` rows: no selection goes to the first (↓) or the last (↑) row; the ends stop the move.
    public static func move(_ selection: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selection, selection < count else { return delta >= 0 ? 0 : count - 1 }
        return min(max(selection + delta, 0), count - 1)
    }
}

/// Keys of the palette and of the panel's keyboard navigation.
public enum PaletteKey: Sendable, Equatable {
    case upArrow, downArrow, returnKey, commandReturn, tab, delete, commandDelete, escape
}

/// What a key does to the selected row.
public enum PaletteCommand: Sendable, Equatable {
    case moveUp, moveDown
    /// Quick activation (`QuickActivation.decide`).
    case activate
    case extend
    /// The full Activation Sheet (justification, ticket, another duration).
    case openSheet
    /// Asks before deactivating.
    case confirmDeactivate
    case close
    /// Not handled: the key goes on to the focused view (the search field types, deletes, clears).
    case pass

    /// `kind`: the selected row, nil without a selection. `queryEmpty`: ⌫ deletes the search text while there is some,
    /// ⌘⌫ always means Deactivate. `escapeCloses`: the palette closes on Escape; the panel leaves it to the search field.
    public static func forKey(_ key: PaletteKey, kind: PaletteKind?, queryEmpty: Bool, escapeCloses: Bool) -> PaletteCommand {
        switch key {
        case .upArrow: return .moveUp
        case .downArrow: return .moveDown
        case .escape: return escapeCloses ? .close : .pass
        case .returnKey:
            switch kind {
            case .eligible?: return .activate
            case .active?: return .extend
            case nil: return .pass
            }
        case .commandReturn, .tab:
            return kind == .eligible ? .openSheet : .pass
        case .delete:
            return kind == .active && queryEmpty ? .confirmDeactivate : .pass
        case .commandDelete:
            return kind == .active ? .confirmDeactivate : .pass
        }
    }
}

// MARK: - Global shortcut

/// The global shortcut opening the palette: a key and its modifiers, stored as « control+option+P », « none » when
/// turned off. Key codes are the ANSI virtual key codes (`kVK_ANSI_*`); Carbon is left to the app.
public struct GlobalShortcut: Sendable, Equatable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public let key: String
    public let modifiers: Modifiers

    /// Keys a shortcut may use: letters and Space.
    public static let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13,
        "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45,
        "M": 46, "Space": 49
    ]

    /// Nil for an unknown key, or without Control, Option or Command (Shift alone would steal typing).
    public init?(key: String, modifiers: Modifiers) {
        let key = key.count == 1 ? key.uppercased() : key
        guard Self.keyCodes[key] != nil, !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        self.init(checked: key, modifiers)
    }

    private init(checked key: String, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// ⌃⌥P.
    public static let defaultShortcut = GlobalShortcut(checked: "P", [.control, .option])
    public static let noneValue = "none"
    /// Choices of Settings › General (none is offered apart).
    public static let presets: [GlobalShortcut] = [
        defaultShortcut, GlobalShortcut(checked: "A", [.control, .option]), GlobalShortcut(checked: "Space", [.control, .option]),
        GlobalShortcut(checked: "P", [.option, .command]), GlobalShortcut(checked: "P", [.control, .shift, .command])
    ]

    public var keyCode: UInt32 { Self.keyCodes[key] ?? 0 }

    private struct ModifierName {
        let flag: Modifiers
        let name: String
        let symbol: String
    }

    /// In the macOS menu order.
    private static let names = [
        ModifierName(flag: .control, name: "control", symbol: "⌃"), ModifierName(flag: .option, name: "option", symbol: "⌥"),
        ModifierName(flag: .shift, name: "shift", symbol: "⇧"), ModifierName(flag: .command, name: "command", symbol: "⌘")
    ]

    /// « ⌃⌥P », « ⌃⌥Space ».
    public var display: String {
        Self.names.filter { modifiers.contains($0.flag) }.map(\.symbol).joined() + key
    }

    public var storageValue: String {
        (Self.names.filter { modifiers.contains($0.flag) }.map(\.name) + [key]).joined(separator: "+")
    }

    /// The stored preference: nil (not set) is the default ⌃⌥P, « none » is off, anything unreadable is the default.
    public static func fromStorage(_ value: String?) -> GlobalShortcut? {
        guard let value else { return defaultShortcut }
        if value == noneValue { return nil }
        var parts = value.split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return defaultShortcut }
        var modifiers: Modifiers = []
        for part in parts {
            guard let modifier = names.first(where: { $0.name == part.lowercased() }) else { return defaultShortcut }
            modifiers.insert(modifier.flag)
        }
        return GlobalShortcut(key: key, modifiers: modifiers) ?? defaultShortcut
    }
}
