import Testing
@testable import AzPimCore

/// Keyboard-first activation: when a role may skip the sheet, palette ranking, keys and the global shortcut.
struct QuickActivationTests {
    private let open = RolePolicy(maxDuration: "PT8H", requiresJustification: false)

    @Test func sendsTheDefaultDurationWhenNothingIsRequired() {
        let decision = QuickActivation.decide(.init(policy: open, policyKnown: true))
        #expect(decision == .send(ActivationInput(duration: "PT1H", justification: "")))
    }

    /// The remembered duration is used; an optional justification is always sent empty (never an old one unseen).
    @Test func usesTheRememberedDurationAndNoJustification() {
        let decision = QuickActivation.decide(.init(policy: open, policyKnown: true, lastDuration: "PT45M"))
        #expect(decision == .send(ActivationInput(duration: "PT45M", justification: "")))
    }

    @Test func theDurationIsCappedByThePolicy() {
        let short = RolePolicy(maxDuration: "PT30M", requiresJustification: false)
        let decision = QuickActivation.decide(.init(policy: short, policyKnown: true, lastDuration: "PT4H"))
        #expect(decision == .send(ActivationInput(duration: "PT30M", justification: "")))
    }

    @Test func aRequiredJustificationOpensTheSheet() {
        let policy = RolePolicy(maxDuration: "PT8H", requiresJustification: true)
        #expect(QuickActivation.decide(.init(policy: policy, policyKnown: true)) == .openSheet)
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
        #expect(QuickPalette.rank("azure", entries).map(\.id) == ["e2", "a1"])   // equal score: eligible first
        #expect(QuickPalette.rank("root", entries).map(\.id) == ["a1"])
    }

    @Test func caseAndAccentsAreIgnored() {
        #expect(QuickPalette.rank("SÉCURITY", entries).map(\.id) == ["e3"])
    }

    @Test func everyWordMustMatch() {
        #expect(QuickPalette.rank("reader owner", entries).isEmpty)
    }

    /// Return activates an eligible row and does nothing on an active one: at equal score the eligible row wins.
    @Test func eligibleRowsWinATie() {
        let tie = [entry("a1", "Reader", kind: .active), entry("e1", "Reader")]
        #expect(QuickPalette.rank("reader", tie).map(\.id) == ["e1", "a1"])
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
    private func command(_ key: PaletteKey, _ kind: PaletteKind?, isRepeat: Bool = false, queryEmpty: Bool = true,
                         escapeCloses: Bool = true) -> PaletteCommand {
        PaletteCommand.forKey(key, kind: kind, isRepeat: isRepeat, queryEmpty: queryEmpty, escapeCloses: escapeCloses)
    }

    @Test func returnActivatesAnEligibleRow() {
        #expect(command(.returnKey, .eligible) == .activate)
        #expect(command(.returnKey, nil) == .pass)
    }

    /// Return never extends: on an active row it only shows how to.
    @Test func returnOnAnActiveRowDoesNothing() {
        #expect(command(.returnKey, .active) == .alreadyActive)
        #expect(PaletteCommand.alreadyActiveHint(locale: english).contains("⇧↩ Extend"))
    }

    @Test func shiftReturnExtendsAnActiveRow() {
        #expect(command(.shiftReturn, .active) == .extend)
        #expect(command(.shiftReturn, .eligible) == .pass)
        #expect(command(.shiftReturn, nil) == .pass)
    }

    @Test func commandReturnAndTabOpenTheSheetOfAnEligibleRole() {
        #expect(command(.commandReturn, .eligible) == .openSheet)
        #expect(command(.tab, .eligible) == .openSheet)
        #expect(command(.commandReturn, .active) == .pass)
        #expect(command(.tab, nil) == .pass)
    }

    /// ⌫ and ⌘⌫ edit the search while there is text.
    @Test func deleteDeactivatesOnlyWithoutSearchText() {
        #expect(command(.delete, .active) == .confirmDeactivate)
        #expect(command(.commandDelete, .active) == .confirmDeactivate)
        #expect(command(.delete, .active, queryEmpty: false) == .pass)
        #expect(command(.commandDelete, .active, queryEmpty: false) == .pass)
        #expect(command(.delete, .eligible) == .pass)
        #expect(command(.commandDelete, .eligible) == .pass)
    }

    /// A held key never activates, extends or asks again; a held ⌫ goes back to the search field. Arrows repeat.
    @Test func repeatedActionKeysAreIgnored() {
        #expect(command(.returnKey, .eligible, isRepeat: true) == .ignore)
        #expect(command(.shiftReturn, .active, isRepeat: true) == .ignore)
        #expect(command(.commandReturn, .eligible, isRepeat: true) == .ignore)
        #expect(command(.tab, .eligible, isRepeat: true) == .ignore)
        #expect(command(.commandDelete, .active, isRepeat: true) == .ignore)
        #expect(command(.delete, .active, isRepeat: true) == .pass)
        #expect(command(.downArrow, .active, isRepeat: true) == .moveDown)
        #expect(command(.upArrow, nil, isRepeat: true) == .moveUp)
    }

    @Test func escapeClosesThePaletteOnly() {
        #expect(command(.escape, .eligible) == .close)
        #expect(command(.escape, .eligible, escapeCloses: false) == .pass)
    }
}

struct PaletteSessionTests {
    private let ids = ["e1", "e2", "a1"]

    @Test func selectionFollowsTheRowNotItsIndex() {
        var session = PaletteSession(selectedId: "e2")
        #expect(session.index(in: ids) == 1)
        #expect(session.index(in: ["a1", "e2"]) == 1)   // rows reordered: still e2
        #expect(session.index(in: ["a1"]) == 0)        // gone: the first row
        #expect(PaletteSession().index(in: []) == nil)
        session.move(by: 1, in: ids)
        #expect(session.selectedId == "a1")
        session.move(by: 1, in: ids)
        #expect(session.selectedId == "a1")
    }

    @Test func aQueryChangeDropsTheQuestionAndTheMessage() {
        var session = PaletteSession(selectedId: "a1")
        session.ask("a1")
        session.message = "Extending…"
        session.queryChanged("own", firstId: "e1")
        #expect(session.confirming == nil)
        #expect(session.message == nil)
        #expect(session.selectedId == "e1")
    }

    /// An empty search with nothing chosen selects no row: Return does nothing, the first ↓ selects the first row.
    @Test func anEmptySearchSelectsNothingUntilDown() {
        var session = PaletteSession()
        #expect(session.index(in: ids) == nil)
        #expect(PaletteCommand.forKey(.returnKey, kind: session.index(in: ids).map { _ in .eligible }, queryEmpty: true,
                                      escapeCloses: true) == .pass)
        session.move(by: 1, in: ids)
        #expect(session.selectedId == "e1")
        // Typing then clearing the search drops the selection again.
        session.queryChanged("own", firstId: "e2")
        #expect(session.selectedId == "e2")
        session.queryChanged("", firstId: "e1")
        #expect(session.index(in: ids) == nil)
    }

    @Test func aSelectionChangeDropsTheQuestion() {
        var session = PaletteSession(selectedId: "a1")
        session.ask("a1")
        session.move(by: -1, in: ids)
        #expect(session.confirming == nil)
        #expect(session.selectedId == "e2")
    }

    @Test func escapeKeepsTheRole() {
        var session = PaletteSession(selectedId: "a1")
        session.ask("a1")
        #expect(session.answer(.escape, isRepeat: false) == .keep)
        #expect(session.confirming == nil)
        #expect(session.answer(.returnKey, isRepeat: false) == .none)
    }

    /// The held ⌫ that asked cannot confirm by repeat; a fresh Return does, and then holds the action keys until the
    /// key is released (no second action from the same press).
    @Test func returnConfirmsOnceThenHoldsUntilKeyUp() {
        var session = PaletteSession(selectedId: "a1")
        session.ask("a1")
        #expect(session.answer(.returnKey, isRepeat: true) == .ignored)
        #expect(session.confirming == "a1")
        #expect(session.answer(.returnKey, isRepeat: false) == .deactivate("a1"))
        #expect(!session.allows(.returnKey))
        #expect(!session.allows(.delete))
        #expect(session.allows(.downArrow))
        session.keyUp()
        #expect(session.allows(.returnKey))
    }

    @Test func anotherKeyDropsTheQuestion() {
        var session = PaletteSession(selectedId: "a1")
        session.ask("a1")
        #expect(session.answer(.tab, isRepeat: false) == .dropped)
        #expect(session.confirming == nil)
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
        // Keys that move on AZERTY (the label would lie) and ⌃⌥Space (input sources) are not offered.
        for key in ["A", "Q", "Z", "W", "M", "Space"] {
            #expect(GlobalShortcut(key: key, modifiers: [.control, .option]) == nil)
        }
        #expect(GlobalShortcut.fromStorage("control+option+A") == GlobalShortcut.defaultShortcut)
        // Unreadable stored values fall back to the default rather than turning the shortcut off.
        #expect(GlobalShortcut.fromStorage("hyper+P") == GlobalShortcut.defaultShortcut)
        #expect(GlobalShortcut.fromStorage("shift+P") == GlobalShortcut.defaultShortcut)
    }
}
