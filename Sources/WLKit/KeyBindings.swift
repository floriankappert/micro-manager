import Foundation

/// User-configurable text macros for the spare keys.
///
/// Read from `$XDG_CONFIG_HOME/micromanager/config.json`
/// (`~/.config/micromanager/config.json` by default):
///
///     {
///       "keys": {
///         "9": "Open PRs for all active GitButler branches",
///         "12": "Run but pull",
///         "10+11": "Summarise what you are working on"
///       },
///       "voice": [11, 12],
///       "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
///       "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
///     }
///
/// A bound string is injected into the focused agent's prompt, unsubmitted,
/// and wins over whatever the key would otherwise do — so the stack and land
/// keys can be given text on a machine without GitButler, and an agent key can
/// be traded for a macro.
/// `"10+11"` addresses the wide key as one; `"10"` and `"11"` address its
/// halves separately. Keys the file does not mention keep their defaults —
/// 9 and 12 have the defaults below, the wide key defaults to the voice key.
/// An empty string unbinds a key outright.
///
/// `"voice"` names the keys that tap right command for Superwhisper. The
/// default is the wide key's two matrix positions, 10 and 11; a pad whose
/// bottom row is single keys can point it elsewhere. A voice key loses its
/// default macro, but an explicit `"keys"` entry on it still wins.
public struct KeyBindings: Sendable, Equatable {

    public private(set) var texts: [Int: String]
    /// The keys that act as the voice key. Presses tap right command and the
    /// lights show the voice colour, unless `texts` rebinds one of them.
    public private(set) var voiceKeys: [Int]
    /// The models the joystick cycles through in Claude Code, in order.
    /// Overridable with a top-level `"claude": {"models": [...]}` object.
    public private(set) var claudeModels: [String]
    /// The effort ladder the dial climbs in Claude Code.
    public private(set) var claudeEfforts: [String]
    /// Codex's own `/model` menu, in the order it lists them, from a
    /// `"codex": {"models": [...]}` object. The joystick steers that menu
    /// rather than owning it, so this is the user's copy of what it offers —
    /// there is nothing to read it from, and no sensible default. Empty means
    /// the panel shows the steering guide alone.
    public private(set) var codexModels: [String]

    public static let defaults: [Int: String] = [
        9: "Open PRs for all active GitButler branches",
        12: "Run but pull",
    ]
    public static let defaultClaudeModels = ["fable", "opus", "sonnet", "haiku"]
    public static let defaultClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init(
        texts: [Int: String] = KeyBindings.defaults,
        voiceKeys: [Int] = Pad.voiceKeyIDs,
        claudeModels: [String] = KeyBindings.defaultClaudeModels,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        codexModels: [String] = []
    ) {
        self.texts = texts
        self.voiceKeys = voiceKeys
        self.claudeModels = claudeModels
        self.claudeEfforts = claudeEfforts
        self.codexModels = codexModels
    }

    /// The string bound to a key, or nil when the key does something else.
    public func text(for key: Int) -> String? {
        guard let text = texts[key], !text.isEmpty else { return nil }
        return text
    }

    /// Every key the file binds a non-empty string to. These act as macro
    /// keys whatever else the key would have done.
    public var textKeys: Set<Int> {
        Set(texts.filter { !$0.value.isEmpty }.keys)
    }

    /// Whether a press on this key is the voice toggle: a voice key with no
    /// text macro over it.
    public func isVoiceKey(_ key: Int) -> Bool {
        text(for: key) == nil && voiceKeys.contains(key)
    }

    /// Every key whose light the bindings decide: the macro keys and the
    /// voice keys, each once, in pad order.
    public var flexKeys: [Int] {
        Array(Set(Pad.macroKeyIDs + voiceKeys)).sorted()
    }

    public static func configPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("micromanager/config.json")
    }

    public static func load() -> KeyBindings {
        guard let data = FileManager.default.contents(atPath: configPath()) else {
            return KeyBindings()
        }
        return parse(data)
    }

    /// A malformed file falls back to the defaults rather than a dead pad.
    static func parse(_ data: Data) -> KeyBindings {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KeyBindings() }

        // Ints or strings, anything else is ignored; an empty or malformed
        // list keeps the wide key.
        let voice = (json["voice"] as? [Any])?.compactMap { item -> Int? in
            (item as? Int) ?? (item as? String).flatMap(Int.init)
        } ?? []
        let voiceKeys = voice.isEmpty ? Pad.voiceKeyIDs : voice

        // A key made a voice key sheds its default macro; the file's own
        // entries below still override.
        var texts = defaults.filter { !voiceKeys.contains($0.key) }
        if let keys = json["keys"] as? [String: Any] {
            for (name, value) in keys {
                guard let text = value as? String else { continue }
                for key in keyIDs(for: name, voiceKeys: voiceKeys) {
                    if text.isEmpty {
                        texts.removeValue(forKey: key)
                    } else {
                        texts[key] = text
                    }
                }
            }
        }

        let claude = json["claude"] as? [String: Any]
        let models = (claude?["models"] as? [String])?.filter { !$0.isEmpty }
        let efforts = (claude?["efforts"] as? [String])?.filter { !$0.isEmpty }
        let codex = json["codex"] as? [String: Any]
        let codexModels = (codex?["models"] as? [String])?.filter { !$0.isEmpty }
        return KeyBindings(
            texts: texts,
            voiceKeys: voiceKeys,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? []
        )
    }

    private static func keyIDs(for name: String, voiceKeys: [Int]) -> [Int] {
        // The wide key spoken of as one: whatever keys currently play its role.
        if name == "10+11" { return voiceKeys }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
