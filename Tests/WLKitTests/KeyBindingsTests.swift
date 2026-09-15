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

    func testCodexModelsComeFromTheFile() {
        let bindings = parse(#"{"codex": {"models": ["gpt-5.6-sol", "gpt-5.6-codex"]}}"#)
        XCTAssertEqual(bindings.codexModels, ["gpt-5.6-sol", "gpt-5.6-codex"])
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels,
                       "a codex-only config leaves the claude side alone")
    }
}
