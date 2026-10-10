import XCTest
@testable import WLKit

final class KeyBindingsTests: XCTestCase {

    private func parse(_ json: String) -> KeyBindings {
        KeyBindings.parse(Data(json.utf8))
    }

    func testMissingFileMeansDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertNil(bindings.text(for: 10), "the wide key defaults to voice, not text")
        XCTAssertNil(bindings.text(for: 11))
    }

    /// The defaults are meaningless on a key the pad does not route to a macro,
    /// so the two lists have to keep agreeing.
    func testDefaultsSitOnTheMacroKeys() {
        XCTAssertEqual(KeyBindings.defaults.keys.sorted(), Pad.macroKeyIDs.sorted())
        XCTAssertFalse(Pad.macroKeyIDs.contains(Pad.landKeyID),
                       "the land key answers before any macro on it would")
    }

    func testFileOverridesAKeyAndKeepsTheOtherDefault() {
        let bindings = parse(#"{"keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 9), "Ship it")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
    }

    /// "10+11" is the wide key spoken of as one: both halves get the string.
    func testWideKeyBindsBothHalvesTogether() {
        let bindings = parse(#"{"keys": {"10+11": "Summarise your progress"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "Summarise your progress")
        XCTAssertEqual(bindings.text(for: 11), "Summarise your progress")
    }

    /// A pad with single keys where the wide cap sits can move the voice role.
    func testVoiceKeysCanMove() {
        let bindings = parse(#"{"voice": [11, 12]}"#)
        XCTAssertEqual(bindings.voiceKeys, [11, 12])
        XCTAssertTrue(bindings.isVoiceKey(11))
        XCTAssertTrue(bindings.isVoiceKey(12))
        XCTAssertNil(bindings.text(for: 12), "a voice key sheds its default macro")
        XCTAssertFalse(bindings.isVoiceKey(10))
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
        XCTAssertEqual(bindings.flexKeys, [9, 10, 11, 12].filter { $0 != 10 })
    }

    func testVoiceKeysAcceptStringsAndDefaultWhenEmpty() {
        XCTAssertEqual(parse(#"{"voice": ["11", "12"]}"#).voiceKeys, [11, 12])
        XCTAssertEqual(parse(#"{"voice": []}"#).voiceKeys, Pad.voiceKeyIDs)
        XCTAssertEqual(parse(#"{}"#).voiceKeys, Pad.voiceKeyIDs)
    }

    func testExplicitTextStillWinsOnAVoiceKey() {
        let bindings = parse(#"{"voice": [11, 12], "keys": {"12": "Run but pull"}}"#)
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertFalse(bindings.isVoiceKey(12))
        XCTAssertTrue(bindings.isVoiceKey(11))
    }

    /// The top row is not wired the same way on every pad, so the order the
    /// agent keys fill has to be movable without a rebuild.
    func testAgentKeyOrderCanBeSwapped() {
        let bindings = parse(#"{"agents": [0, 1, 2, 3, 4, 5]}"#)
        XCTAssertEqual(bindings.agentKeys, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(bindings.agentSlot(for: 0), 0, "first agent on the other top key")
        XCTAssertEqual(bindings.agentSlot(for: 1), 1)
        XCTAssertNil(bindings.agentSlot(for: Pad.stackKeyID))
    }

    /// The drawn pad has to agree with the real one, or the panel shows the
    /// top row mirrored against the hardware.
    func testDisplayRowsFollowTheAgentKeyOrder() {
        XCTAssertEqual(KeyBindings().displayRows, Pad.displayRows, "default pad is unchanged")

        let swapped = parse(#"{"agents": [0, 1, 2, 3, 4, 5]}"#).displayRows
        XCTAssertEqual(swapped[0], [0, 1], "top row follows the configured order")
        XCTAssertEqual(swapped[1], [2, 3, 4, 5])
        XCTAssertEqual(Array(swapped.dropFirst(2)), Array(Pad.displayRows.dropFirst(2)),
                       "the lower rows are the same on every pad")
        XCTAssertEqual(swapped.flatMap { $0 }.sorted(), Pad.rows.flatMap { $0 }.sorted(),
                       "every key still appears exactly once")
    }

    /// Half-applying a bad list would leave an agent with no key and nothing
    /// to say why, so anything that is not the six keys exactly is ignored.
    func testBadAgentKeyOrderIsIgnored() {
        XCTAssertEqual(parse(#"{"agents": [0, 0, 2, 3, 4, 5]}"#).agentKeys, Pad.agentKeyIDs,
                       "a duplicate is not a permutation")
        XCTAssertEqual(parse(#"{"agents": [0, 1, 2]}"#).agentKeys, Pad.agentKeyIDs)
        XCTAssertEqual(parse(#"{"agents": [0, 1, 2, 3, 4, 9]}"#).agentKeys, Pad.agentKeyIDs,
                       "9 is a macro key, not an agent key")
        XCTAssertEqual(parse(#"{}"#).agentKeys, Pad.agentKeyIDs)
        XCTAssertEqual(parse(#"{"agents": [0, 1, 2, 3, 4, 5, 6, 6]}"#).agentKeys, Pad.agentKeyIDs,
                       "an extra key given twice")
        XCTAssertEqual(parse(#"{"agents": [0, 1, 2, 3, 4, 5, 13]}"#).agentKeys, Pad.agentKeyIDs,
                       "13 is not a key of the pad")
    }

    /// More agents than the top rows hold: row three can be handed to agents,
    /// and its keys then do nothing else - no stack, no tab cycle, no land.
    func testExtraAgentKeysTakeOverBuiltInRoles() {
        let bindings = parse(#"{"agents": [0, 1, 2, 3, 4, 5, 6, 7, 8]}"#)
        XCTAssertEqual(bindings.agentKeys, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(bindings.agentSlot(for: Pad.stackKeyID), 6)
        XCTAssertEqual(bindings.agentSlot(for: Pad.landKeyID), 8)
        XCTAssertFalse(bindings.keepsBuiltInRole(Pad.stackKeyID))
        XCTAssertFalse(bindings.keepsBuiltInRole(Pad.tabCycleKeyID))
        XCTAssertTrue(bindings.keepsBuiltInRole(9))
        XCTAssertEqual(bindings.displayRows[2], [6, 7, 8, 9], "row three stays in pad order")
        XCTAssertEqual(bindings.displayRows.flatMap { $0 }.sorted(), Pad.rows.flatMap { $0 }.sorted())
    }

    /// A macro key claimed for an agent sheds its default text, and is painted
    /// as an agent, once - unless the file binds text to it on purpose.
    func testAgentKeyShedsDefaultMacro() {
        let bindings = parse(#"{"agents": [0, 1, 2, 3, 4, 5, 9], "voice": [12]}"#)
        XCTAssertNil(bindings.text(for: 9))
        XCTAssertFalse(bindings.flexKeys.contains(9))
        XCTAssertTrue(bindings.flexKeys.contains(12))

        let explicit = parse(#"{"agents": [0, 1, 2, 3, 4, 5, 9], "keys": {"9": "hi"}}"#)
        XCTAssertEqual(explicit.text(for: 9), "hi", "an explicit entry still wins")
    }

    func testAgentKeyIsNotAVoiceKey() {
        let bindings = parse(#"{"agents": [0, 1, 2, 3, 4, 5, 12], "voice": [12]}"#)
        XCTAssertFalse(bindings.isVoiceKey(12))
    }

    func testWideKeyHalvesCanDiffer() {
        let bindings = parse(#"{"keys": {"10": "left half", "11": "right half"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "left half")
        XCTAssertEqual(bindings.text(for: 11), "right half")
    }

    /// An empty string unbinds: the key goes dark rather than typing nothing.
    func testEmptyStringUnbindsADefault() {
        let bindings = parse(#"{"keys": {"12": ""}}"#)
        XCTAssertNil(bindings.text(for: 12))
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
    }

    func testMalformedFileFallsBackToDefaults() {
        XCTAssertEqual(parse("not json"), KeyBindings())
        XCTAssertEqual(parse(#"{"keys": "nope"}"#), KeyBindings())
    }

    func testClaudeModelAndEffortListsHaveDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.claudeModels, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeListsAreOverridable() {
        let bindings = parse(#"{"claude": {"models": ["opus", "sonnet"], "efforts": ["low", "high"]}}"#)
        XCTAssertEqual(bindings.claudeModels, ["opus", "sonnet"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches",
                       "key defaults survive a claude-only config")
    }

    func testEmptyClaudeListsFallBackToDefaults() {
        let bindings = parse(#"{"claude": {"models": []}}"#)
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels)
    }

    /// Codex's list has no default to fall back on: it is a copy of what that
    /// TUI offers, and guessing it would put wrong names next to the numbers.
    func testCodexModelsAreEmptyUntilConfigured() {
        XCTAssertEqual(KeyBindings().codexModels, [])
        XCTAssertEqual(parse(#"{"codex": {"models": []}}"#).codexModels, [])
    }

    // MARK: - Keystroke actions

    func testNoActionsByDefault() {
        let bindings = KeyBindings()
        XCTAssertNil(bindings.action(for: 9))
        XCTAssertNil(bindings.action(for: 10))
        XCTAssertEqual(bindings.actionKeys, [])
        XCTAssertEqual(bindings.dial, .effort)
        XCTAssertEqual(bindings.joystick, .model)
    }

    /// The wide key sends enter, the key beside it forward-deletes: a pad with
    /// one cap over 10 and 11 binds both halves at once.
    func testActionsBindKeysAndShedTheirDefaultMacro() {
        let bindings = parse(#"{"actions": {"10+11": "enter", "9": "delete"}}"#)
        XCTAssertEqual(bindings.action(for: 10), .enter)
        XCTAssertEqual(bindings.action(for: 11), .enter)
        XCTAssertEqual(bindings.action(for: 9), .delete)
        XCTAssertNil(bindings.text(for: 9), "a keystroke key sheds its default macro")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull", "other defaults stand")
        XCTAssertEqual(bindings.actionKeys, [9, 10, 11])
        XCTAssertEqual(bindings.flexKeys, [9, 10, 11, 12], "every bound key gets a light")
    }

    /// Same precedence as everywhere else: an explicit string wins, so a key
    /// never both types and presses.
    func testTextWinsOverAnActionOnTheSameKey() {
        let bindings = parse(#"{"actions": {"9": "enter"}, "keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 9), "Ship it")
        XCTAssertNil(bindings.action(for: 9))
        XCTAssertEqual(bindings.actionKeys, [])
    }

    func testAnActionKeyIsNotAVoiceKey() {
        let bindings = parse(#"{"voice": [10, 11], "actions": {"10+11": "enter"}}"#)
        XCTAssertFalse(bindings.isVoiceKey(10))
        XCTAssertFalse(bindings.isVoiceKey(11))
    }

    func testActionNamesAndAliases() {
        XCTAssertEqual(parse(#"{"actions": {"9": "return"}}"#).action(for: 9), .enter)
        XCTAssertEqual(parse(#"{"actions": {"9": "Del"}}"#).action(for: 9), .delete)
        XCTAssertEqual(parse(#"{"actions": {"9": "backspace"}}"#).action(for: 9), .backspace)
        XCTAssertEqual(parse(#"{"actions": {"9": "esc"}}"#).action(for: 9), .escape)
        XCTAssertEqual(parse(#"{"actions": {"9": "volume-up"}}"#).action(for: 9), .volumeUp)
    }

    /// A name the file gets wrong leaves the key as it was rather than
    /// guessing at something else to send.
    func testUnknownActionNameIsIgnored() {
        let bindings = parse(#"{"actions": {"9": "eject"}}"#)
        XCTAssertNil(bindings.action(for: 9))
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches",
                       "the default macro survives a name nothing matched")
    }

    /// `"10+11"` is the cap, not the voice role: it used to resolve to
    /// whatever `voice` named, which quietly missed the wide key once the role
    /// moved to a single key elsewhere.
    func testWideKeyNameMeansTheTwoHalvesEvenWhenVoiceMoved() {
        let bindings = parse(#"{"voice": [12], "actions": {"10+11": "enter"}}"#)
        XCTAssertEqual(bindings.action(for: 10), .enter)
        XCTAssertEqual(bindings.action(for: 11), .enter)
        XCTAssertNil(bindings.action(for: 12))
        XCTAssertTrue(bindings.isVoiceKey(12))
    }

    /// For addressing the role rather than the cap under it.
    func testVoiceNameFollowsTheRole() {
        let bindings = parse(#"{"voice": [12], "keys": {"voice": "Summarise"}}"#)
        XCTAssertEqual(bindings.text(for: 12), "Summarise")
        XCTAssertNil(bindings.text(for: 10))
    }

    // MARK: - Dial and joystick roles

    func testDialAndJoystickRolesComeFromTheFile() {
        let bindings = parse(#"{"dial": "volume", "joystick": "agents"}"#)
        XCTAssertEqual(bindings.dial, .volume)
        XCTAssertEqual(bindings.joystick, .agents)
    }

    func testUnknownRolesKeepTheAgentTuning() {
        let bindings = parse(#"{"dial": "brightness", "joystick": "tabs"}"#)
        XCTAssertEqual(bindings.dial, .effort)
        XCTAssertEqual(bindings.joystick, .model)
    }

    func testCodexModelsComeFromTheFile() {
        let bindings = parse(#"{"codex": {"models": ["gpt-5.6-sol", "gpt-5.6-codex"]}}"#)
        XCTAssertEqual(bindings.codexModels, ["gpt-5.6-sol", "gpt-5.6-codex"])
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels,
                       "a codex-only config leaves the claude side alone")
    }
}
