import Testing
@testable import AzPimCore

/// Keyboard-first activation: when a role may skip the sheet, palette ranking, keys and the global shortcut.
struct QuickActivationTests {
    private let open = RolePolicy(maxDuration: "PT8H", requiresJustification: false)

    @Test func sendsTheDefaultDurationWhenNothingIsRequired() {
        let decision = QuickActivation.decide(.init(policy: open, policyKnown: true))
        #expect(decision == .send(ActivationInput(duration: "PT1H", justification: "")))
    }

    @Test func usesTheRememberedDurationAndJustification() {
        let decision = QuickActivation.decide(.init(policy: open, policyKnown: true, lastDuration: "PT45M",
                                                    lastJustification: "Audit"))
        #expect(decision == .send(ActivationInput(duration: "PT45M", justification: "Audit")))
    }

    @Test func theDurationIsCappedByThePolicy() {
        let short = RolePolicy(maxDuration: "PT30M", requiresJustification: false)
        let decision = QuickActivation.decide(.init(policy: short, policyKnown: true, lastDuration: "PT4H"))
        #expect(decision == .send(ActivationInput(duration: "PT30M", justification: "")))
    }

    /// Even with a justification remembered: the user must see what is sent.
    @Test func aRequiredJustificationOpensTheSheet() {
        let policy = RolePolicy(maxDuration: "PT8H", requiresJustification: true)
        #expect(QuickActivation.decide(.init(policy: policy, policyKnown: true)) == .openSheet)
        #expect(QuickActivation.decide(.init(policy: policy, policyKnown: true, lastJustification: "Audit")) == .openSheet)
    }

    @Test func aRequiredTicketOpensTheSheet() {
        let policy = RolePolicy(maxDuration: "PT8H", requiresJustification: false, requiresTicket: true)
        #expect(QuickActivation.decide(.init(policy: policy, policyKnown: true)) == .openSheet)
    }

    @Test func anUnknownPolicyOpensTheSheet() {
        #expect(QuickActivation.decide(.init(policy: open, policyKnown: false)) == .openSheet)
    }

    @Test func blockedStatesSendNothing() {
        #expect(QuickActivation.decide(.init(policy: open, policyKnown: true, inProgress: true)) == .blocked(.inProgress))
        #expect(QuickActivation.decide(.init(policy: open, policyKnown: true, pending: true)) == .blocked(.pending))
        #expect(QuickActivation.decide(.init(policy: open, policyKnown: true, offline: true)) == .blocked(.offline))
        // Blocked before the sheet: opening it would only show the same reason.
        let required = RolePolicy(maxDuration: "PT8H", requiresJustification: true)
        #expect(QuickActivation.decide(.init(policy: required, policyKnown: true, offline: true)) == .blocked(.offline))
    }
}

struct QuickPaletteTests {
    private func entry(_ id: String, _ name: String, scope: String = "Directory", kind: PaletteKind = .eligible,
                       types: [String] = ["Entra", "Entra roles"], tenant: String = "Contoso") -> PaletteEntry {
        PaletteEntry(id: id, kind: kind, name: name, scope: scope, types: types, tenant: tenant)
    }

    private var entries: [PaletteEntry] {
        [entry("a1", "Reader", scope: "Tenant Root Group", kind: .active, types: ["Azure", "Azure roles"]),
         entry("e1", "Global Reader"),
         entry("e2", "Key Vault Administrator", scope: "kv-app-prod", types: ["Azure", "Azure roles"]),
         entry("e3", "Security Reader"),
         entry("e4", "User Administrator")]
    }

    @Test func emptyQueryKeepsTheOrder() {
        #expect(QuickPalette.rank("  ", entries).map(\.id) == ["a1", "e1", "e2", "e3", "e4"])
    }

    @Test func nameStartBeatsAWordStart() {
        // « Reader » starts with the word; « Global Reader » and « Security Reader » only contain it.
        #expect(QuickPalette.rank("read", entries).map(\.id) == ["a1", "e1", "e3"])
        #expect(QuickPalette.rank("glo", entries).map(\.id) == ["e1"])
    }

    @Test func initialsAndSubsequencesMatchTheName() {
        #expect(QuickPalette.rank("kva", entries).first?.id == "e2")
        #expect(QuickPalette.rank("kvadm", entries).map(\.id) == ["e2"])   // subsequence
    }

    @Test func otherFieldsMatchToo() {
        #expect(QuickPalette.rank("contoso user", entries).map(\.id) == ["e4"])
        #expect(QuickPalette.rank("azure", entries).map(\.id) == ["a1", "e2"])
        #expect(QuickPalette.rank("root", entries).map(\.id) == ["a1"])
    }

    @Test func caseAndAccentsAreIgnored() {
        #expect(QuickPalette.rank("SÉCURITY", entries).map(\.id) == ["e3"])
    }

    @Test func everyWordMustMatch() {
        #expect(QuickPalette.rank("reader owner", entries).isEmpty)
    }

    @Test func activeRowsWinATie() {
        let tie = [entry("e1", "Reader"), entry("a1", "Reader", kind: .active)]
        #expect(QuickPalette.rank("reader", tie).map(\.id) == ["a1", "e1"])
    }

    @Test func moveClampsAtTheEnds() {
        #expect(QuickPalette.move(nil, by: 1, count: 3) == 0)
        #expect(QuickPalette.move(nil, by: -1, count: 3) == 2)
        #expect(QuickPalette.move(0, by: -1, count: 3) == 0)
        #expect(QuickPalette.move(2, by: 1, count: 3) == 2)
        #expect(QuickPalette.move(1, by: 1, count: 3) == 2)
        #expect(QuickPalette.move(5, by: 1, count: 3) == 0)   // the list shrank under the selection
        #expect(QuickPalette.move(0, by: 1, count: 0) == nil)
    }
}

struct PaletteCommandTests {
    private func command(_ key: PaletteKey, _ kind: PaletteKind?, queryEmpty: Bool = true,
                         escapeCloses: Bool = true) -> PaletteCommand {
        PaletteCommand.forKey(key, kind: kind, queryEmpty: queryEmpty, escapeCloses: escapeCloses)
    }

    @Test func returnActivatesOrExtends() {
        #expect(command(.returnKey, .eligible) == .activate)
        #expect(command(.returnKey, .active) == .extend)
        #expect(command(.returnKey, nil) == .pass)
    }

    @Test func commandReturnAndTabOpenTheSheetOfAnEligibleRole() {
        #expect(command(.commandReturn, .eligible) == .openSheet)
        #expect(command(.tab, .eligible) == .openSheet)
        #expect(command(.commandReturn, .active) == .pass)
        #expect(command(.tab, nil) == .pass)
    }

    /// ⌫ edits the search while there is text; ⌘⌫ always asks to deactivate.
    @Test func deleteDeactivatesOnlyWithoutSearchText() {
        #expect(command(.delete, .active) == .confirmDeactivate)
        #expect(command(.delete, .active, queryEmpty: false) == .pass)
        #expect(command(.commandDelete, .active, queryEmpty: false) == .confirmDeactivate)
        #expect(command(.delete, .eligible) == .pass)
        #expect(command(.commandDelete, .eligible) == .pass)
    }

    @Test func escapeClosesThePaletteOnly() {
        #expect(command(.escape, .eligible) == .close)
        #expect(command(.escape, .eligible, escapeCloses: false) == .pass)
    }

    @Test func arrowsMove() {
        #expect(command(.upArrow, nil) == .moveUp)
        #expect(command(.downArrow, .active) == .moveDown)
    }
}

struct GlobalShortcutTests {
    @Test func defaultIsControlOptionP() {
        let shortcut = GlobalShortcut.fromStorage(nil)
        #expect(shortcut == GlobalShortcut.defaultShortcut)
        #expect(shortcut?.display == "⌃⌥P")
        #expect(shortcut?.keyCode == 35)
        #expect(shortcut?.storageValue == "control+option+P")
    }

    @Test func noneTurnsItOff() {
        #expect(GlobalShortcut.fromStorage("none") == nil)
    }

    @Test func roundTripsEveryPreset() {
        for preset in GlobalShortcut.presets {
            #expect(GlobalShortcut.fromStorage(preset.storageValue) == preset)
        }
        #expect(Set(GlobalShortcut.presets.map(\.display)).count == GlobalShortcut.presets.count)
    }

    @Test func modifiersDisplayInMacOrder() {
        let shortcut = GlobalShortcut(key: "k", modifiers: [.command, .shift, .control])
        #expect(shortcut?.display == "⌃⇧⌘K")
        #expect(shortcut?.storageValue == "control+shift+command+K")
    }

    @Test func rejectsUnusableShortcuts() {
        #expect(GlobalShortcut(key: "P", modifiers: [.shift]) == nil)
        #expect(GlobalShortcut(key: "P", modifiers: []) == nil)
        #expect(GlobalShortcut(key: "F5", modifiers: [.command]) == nil)
        // Unreadable stored values fall back to the default rather than turning the shortcut off.
        #expect(GlobalShortcut.fromStorage("hyper+P") == GlobalShortcut.defaultShortcut)
        #expect(GlobalShortcut.fromStorage("shift+P") == GlobalShortcut.defaultShortcut)
    }
}
