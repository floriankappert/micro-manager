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
///       "actions": { "10+11": "enter", "9": "delete" },
///       "dial": "volume",
///       "joystick": "agents",
///       "voice": [11, 12],
///       "agents": [0, 1, 2, 3, 4, 5],
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
/// `"actions"` puts a plain keystroke on a key instead of a macro: the pad
/// synthesises it system-wide, so it lands wherever focus is rather than in a
/// Herdr pane. Addressed like `"keys"`, and it sheds a key's default macro the
/// way `"voice"` does; a `"keys"` entry on the same key still wins.
///
/// `"dial"` and `"joystick"` choose what those two controls drive:
/// `"effort"`/`"model"` are the agent tuning they default to, `"volume"` turns
/// the dial into the system volume, and `"agents"` makes the stick walk the
/// agent list — north the next agent, south the previous one.
///
/// `"voice"` names the keys that tap right command for Superwhisper. The
/// default is the wide key's two matrix positions, 10 and 11; a pad whose
/// bottom row is single keys can point it elsewhere. A voice key loses its
/// default macro, but an explicit `"keys"` entry on it still wins.
public struct KeyBindings: Sendable, Equatable {

    /// A keystroke or system command a key can carry instead of a macro.
    /// These are posted as real events, so they reach whatever has focus —
    /// which is the point: enter and delete are only useful where the cursor
    /// already is.
    public enum Action: String, Sendable, CaseIterable {
        case enter
        /// Forward delete, the key marked ⌦ on a full keyboard.
        case delete
        /// The ⌫ key, for a pad that wants the other delete.
        case backspace
        case escape
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"

        /// How the key reads to a human, for the menu's tooltips.
        public var label: String {
            switch self {
            case .enter: return "enter"
            case .delete: return "forward delete"
            case .backspace: return "delete"
            case .escape: return "escape"
            case .volumeUp: return "volume up"
            case .volumeDown: return "volume down"
            }
        }

        /// The config file's spellings, including the aliases worth having.
        static func named(_ name: String) -> Action? {
            switch name.lowercased() {
            case "return": return .enter
            case "forward-delete", "del": return .delete
            case "esc": return .escape
            case "volume+", "louder": return .volumeUp
            case "volume-", "quieter": return .volumeDown
            default: return Action(rawValue: name.lowercased())
            }
        }
    }

    /// What the dial's rotation drives.
    public enum DialRole: String, Sendable {
        /// The focused agent's reasoning effort, the default.
        case effort
        /// System output volume: clockwise louder, counter-clockwise quieter.
        case volume
    }

    /// What the joystick's deflections drive.
    public enum JoystickRole: String, Sendable {
        /// The focused agent's model list, the default.
        case model
        /// Focus, walking Herdr's agent list: north next, south previous.
        case agents
    }

    public private(set) var texts: [Int: String]
    /// Keystrokes bound to keys, which beat every built-in role but lose to a
    /// text macro on the same key.
    public private(set) var actions: [Int: Action]
    public private(set) var dial: DialRole
    public private(set) var joystick: JoystickRole
    /// The keys that act as the voice key. Presses tap right command and the
    /// lights show the voice colour, unless `texts` rebinds one of them.
    public private(set) var voiceKeys: [Int]
    /// The agent keys, in the order agents fill them: agent slot N takes
    /// `agentKeys[N]`.
    ///
    /// Configurable because the top row is not wired the same way on every
    /// pad. The default compensates for a row wired right to left, so the
    /// first agent still lands on the top-left key; a pad wired left to right
    /// wants a plain `[0, 1, 2, 3, 4, 5]` instead. Press a key and watch the
    /// Inspector to see which code a given cap actually sends.
    ///
    /// More keys can follow the six, for more agents than the top two rows
    /// hold: `[0, 1, 2, 3, 4, 5, 6, 7, 8]` gives row three to agents too. A key
    /// taken this way loses its built-in role - stack, tab cycle, land, voice,
    /// default macro - but a `"keys"` or `"actions"` entry on it still wins.
    public private(set) var agentKeys: [Int]
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
        actions: [Int: Action] = [:],
        dial: DialRole = .effort,
        joystick: JoystickRole = .model,
        voiceKeys: [Int] = Pad.voiceKeyIDs,
        agentKeys: [Int] = Pad.agentKeyIDs,
        claudeModels: [String] = KeyBindings.defaultClaudeModels,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        codexModels: [String] = []
    ) {
        self.texts = texts
        self.actions = actions
        self.dial = dial
        self.joystick = joystick
        self.voiceKeys = voiceKeys
        self.agentKeys = agentKeys
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

    /// The keystroke bound to a key, or nil. A text macro on the same key
    /// wins, so this answers nil there too — one key, one job.
    public func action(for key: Int) -> Action? {
        text(for: key) == nil ? actions[key] : nil
    }

    /// Every key a keystroke actually reaches.
    public var actionKeys: Set<Int> {
        Set(actions.keys.filter { action(for: $0) != nil })
    }

    /// The pad as you look at it, with the two agent rows in the configured
    /// order. Rows three and four never move: those ids sit in the same places
    /// on every pad. Drawing a mirror from `Pad.displayRows` instead would
    /// show the top row the wrong way round on a pad that reorders it.
    public var displayRows: [[Int]] {
        // A row made up entirely of agent keys is laid out in agent order,
        // which is reading order; any other row keeps the pad's own.
        Pad.displayRows.map { row in
            let slots = row.compactMap(agentSlot(for:))
            guard slots.count == row.count else { return row }
            return slots.sorted().map { agentKeys[$0] }
        }
    }

    /// The agent slot a key answers for, or nil when it is not an agent key.
    public func agentSlot(for key: Int) -> Int? {
        agentKeys.firstIndex(of: key)
    }

    /// Whether a press on this key is the voice toggle: a voice key with no
    /// text macro, keystroke or agent over it.
    public func isVoiceKey(_ key: Int) -> Bool {
        text(for: key) == nil && action(for: key) == nil && agentSlot(for: key) == nil
            && voiceKeys.contains(key)
    }

    /// Whether the key still does what `Pad` gives it - the stack, tab-cycle
    /// or land role. False once `"agents"` claims it.
    public func keepsBuiltInRole(_ key: Int) -> Bool {
        agentSlot(for: key) == nil
    }

    /// Every key whose light the bindings decide: the macro keys and the
    /// voice keys, each once, in pad order. Agent keys are painted as agents
    /// even where one is also named here, so each key is painted once.
    public var flexKeys: [Int] {
        Array(Set(Pad.macroKeyIDs + voiceKeys).union(actionKeys))
            .filter { agentSlot(for: $0) == nil }
            .sorted()
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

        // Same shape as "voice". The six agent keys must all be there, each
        // once, and anything after them must be a key of the pad; a list that
        // is not is ignored rather than half-applied, since a duplicate or a
        // stray id would leave an agent with no key and no way to tell.
        let agents = (json["agents"] as? [Any])?.compactMap { item -> Int? in
            (item as? Int) ?? (item as? String).flatMap(Int.init)
        } ?? []
        let agentKeys = Set(agents).count == agents.count
            && Set(agents).isSuperset(of: Pad.agentKeyIDs)
            && agents.allSatisfy { (0..<Pad.keyCount).contains($0) }
            ? agents : Pad.agentKeyIDs

        // Names the file does not know are ignored rather than guessed at: a
        // typo should leave the key doing what it did, not something else.
        var actions: [Int: Action] = [:]
        if let bound = json["actions"] as? [String: Any] {
            for (name, value) in bound {
                guard let spelling = value as? String,
                      let action = Action.named(spelling)
                else { continue }
                for key in keyIDs(for: name, voiceKeys: voiceKeys) {
                    actions[key] = action
                }
            }
        }

        // A key made a voice or action key sheds its default macro; the file's
        // own entries below still override.
        var texts = defaults.filter {
            !voiceKeys.contains($0.key) && actions[$0.key] == nil && !agentKeys.contains($0.key)
        }
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
            actions: actions,
            dial: (json["dial"] as? String).flatMap { DialRole(rawValue: $0.lowercased()) } ?? .effort,
            joystick: (json["joystick"] as? String)
                .flatMap { JoystickRole(rawValue: $0.lowercased()) } ?? .model,
            voiceKeys: voiceKeys,
            agentKeys: agentKeys,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? []
        )
    }

    private static func keyIDs(for name: String, voiceKeys: [Int]) -> [Int] {
        // The wide key spoken of as one: the two matrix positions under that
        // cap, whatever they are used for. It used to mean "the voice keys",
        // which reads the same while the wide key is the voice key and
        // silently misses once the role moves elsewhere.
        if name == "10+11" { return [10, 11] }
        // For addressing the role rather than the cap.
        if name == "voice" { return voiceKeys }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
