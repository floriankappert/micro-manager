import Foundation
import SwiftUI

/// Maps a set of Herdr agents to device lighting.
///
/// Keys are individually addressable, so each agent gets its own key. The
/// underglow keeps a worst-state-wins aggregate, which is the part you can read
/// from across the room without counting keys.
///
/// Kept in step with `lib/status.js`; the defaults below are that file's.
public struct BridgeConfig: Sendable {
    /// Highest priority first: the first state present across all agents wins
    /// the underglow.
    public var priority: [String] = ["blocked", "working", "testing", "deploying", "review", "finished", "done", "idle", "unknown"]
    public var colors: [String: Int] = [
        "blocked": 0xFF2D2D,
        // Three neighbours that must stay apart: working is yellow-orange,
        // testing a true orange, deploying lemon yellow. LED-strength
        // versions of bhote's hues (pastels wash out to white on an LED);
        // review is its blue, offline its muted grey.
        "working": 0xFFA000,
        "testing": 0xFF5A00,
        "deploying": 0xFFE600,
        // Herdr reports "done" for an agent that has finished and that you
        // have not looked at yet, and "idle" once it is focused. That is a
        // real difference - one is waiting to be read, the other is just
        // quiet - so done is lit green and idle is dark.
        "done": 0x00C853,
        // Review is an idle agent that bhote has waiting on you (it asked a
        // question): blue, as in bhote's panel.
        "review": 0x2979FF,
        // Finished is an idle agent that bhote has stopped without a
        // question. Green, and quick, so it reads apart from done's slow
        // breath. The pad has no blink effect; this is the nearest thing.
        "finished": 0x00C853,
        "idle": 0x000000,
        "offline": 0x607080,
        "unknown": 0x000000,
    ]
    /// Only the two "something is in progress elsewhere" states breathe;
    /// everything else is a steady light.
    public var effects: [String: OAI.Effect] = [
        "blocked": .solid,
        "working": .solid,
        "testing": .breath,
        "deploying": .breath,
        "offline": .solid,
        "idle": .off,
        "done": .solid,
        "review": .solid,
        "finished": .solid,
        "unknown": .off,
    ]
    /// Where the underglow differs from the keys. Nothing does any more: only
    /// testing and deploying breathe, on the keys and the underglow alike.
    public var zoneEffects: [String: OAI.Effect] = [
        "working": .solid,
    ]
    /// Brightness relative to `brightness`: what needs you is full, and what
    /// is calm (idle) or unknown is dark.
    public var brightnesses: [String: Double] = [
        "blocked": 1,
        "done": 1,
        "review": 1,
        "finished": 1,
        "working": 0.8,
        "testing": 0.8,
        "deploying": 0.8,
        "offline": 0.25,
        "idle": 0,
        "unknown": 0,
    ]
    /// Breathing pace of the two states that breathe.
    public var speeds: [String: Double] = [
        "testing": 0.6,
        "deploying": 0.6,
    ]
    /// The stack key is not an agent, so it gets a colour of its own rather
    /// than borrowing one of the status colours.
    public var stackColor: Int = 0x7C4DFF
    /// Same reasoning for the tab-cycle key, in a colour of its own so the two
    /// action keys read as different things.
    public var tabCycleColor: Int = 0x00BFA5
    /// The land key pushes to the target, so it gets a colour with some weight
    /// to it — distinct from blocked-red, which means "look", not "beware".
    public var landColor: Int = 0xE91E63
    /// The voice key is purple. Waiting for input it is steady, listening it
    /// breathes slowly and processing it breathes fast.
    public var voiceColor: Int = 0xAA00FF
    public var voiceListeningSpeed: Double = 0.3
    public var voiceProcessingSpeed: Double = 0.9
    /// Text-macro keys: a quiet steel blue — bound, but not status-bearing.
    public var macroColor: Int = 0x90A4AE
    /// Master level for every light on the pad, keys and underglow alike, by
    /// day. At night `nightBrightness` takes over; see `lit(at:)`.
    public var brightness: Double = 1
    public var nightBrightness: Double = 1
    /// Night runs from `nightStartHour` to `nightEndHour` local time, across
    /// midnight.
    public var nightStartHour = 22
    public var nightEndHour = 7
    public var speed: Double = 0.2
    /// Leave the key-backlight ZONE alone: keys are painted per-agent instead,
    /// and a zone colour would only compete with them.
    public var driveBacklight = false
    /// Bind the keys this app drives to `KV_OAI_AG*` on startup. Required for
    /// per-key colour to work at all.
    public var manageKeymap = true
    public var pollInterval: TimeInterval = 2.5
    public var debounce: TimeInterval = 0.1

    public init() {}

    public func isNight(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return nightStartHour > nightEndHour
            ? hour >= nightStartHour || hour < nightEndHour
            : hour >= nightStartHour && hour < nightEndHour
    }

    /// This config with the master brightness for the time of day. Everything
    /// that paints the pad goes through it, so one value dims it all.
    public func lit(at date: Date = Date(), calendar: Calendar = .current) -> BridgeConfig {
        var copy = self
        if isNight(at: date, calendar: calendar) { copy.brightness = nightBrightness }
        return copy
    }

    /// A status Herdr invents later reads as `unknown`, i.e. dark, rather
    /// than borrowing some other state's look.
    /// Bhote marks an agent on a machine that is reconnecting as `off-<status>`.
    private func known(_ state: String) -> String {
        if state.hasPrefix("off-") { return "offline" }
        return colors[state] == nil ? "unknown" : state
    }

    public func color(for state: String) -> Int { colors[known(state)] ?? 0 }
    public func effect(for state: String) -> OAI.Effect { effects[known(state)] ?? .off }
    public func brightness(for state: String) -> Double { brightness * (brightnesses[known(state)] ?? 0) }
    public func speed(for state: String) -> Double { speeds[known(state)] ?? speed }
}

public enum StatusMapper {

    /// The winning state across all agents, or nil when none are running.
    public static func aggregate(_ agents: [HerdrAgent], _ cfg: BridgeConfig = BridgeConfig()) -> String? {
        guard !agents.isEmpty else { return nil }
        let present = Set(agents.map(\.status))
        for state in cfg.priority where present.contains(state) { return state }
        return "unknown"
    }

    /// One thread entry per agent key: agent slot N takes `Pad.agentKeyIDs[N]`
    /// — reading order on the pad — and unused keys go dark. Always returns
    /// exactly `Pad.agentKeyIDs.count` entries, so a vanished agent actively
    /// clears its key rather than leaving it stale.
    public static func threads(
        for agents: [HerdrAgent],
        keys: [Int] = Pad.agentKeyIDs,
        workingSince: [Date?] = [],
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> [OAI.Thread] {
        keys.enumerated().map { slot, id in
            guard slot < agents.count else {
                return OAI.Thread(id: id, brightness: 0, effect: .off)
            }
            let state = agents[slot].status
            return OAI.Thread(
                id: id,
                color: cfg.color(for: state),
                brightness: cfg.brightness(for: state),
                effect: cfg.effect(for: state),
                speed: state == "working" && slot < workingSince.count
                    ? breathSpeed(base: cfg.speed(for: state), since: workingSince[slot])
                    : cfg.speed(for: state)
            )
        }
    }

    /// Working keys breathe at a pace nudged by when each agent started, so two
    /// of them drift apart instead of pulsing in lockstep. The nudge is a
    /// pure function of the start time (+-8 %), so a repaint never changes it.
    public static func breathSpeed(base: Double, since: Date?) -> Double {
        guard let since else { return base }
        let step = Int(since.timeIntervalSinceReferenceDate) % 7
        return base * (0.92 + 0.0267 * Double(step))
    }

    /// The stack key's own thread. It stays lit whenever the bridge is
    /// running: binding it to an AG keycode took away the keystroke it used to
    /// send, so an unlit key would just read as broken. Breathing while the
    /// stack is on screen, since the same key is what dismisses it.
    public static func stackThread(
        open: Bool,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        OAI.Thread(
            id: Pad.stackKeyID,
            color: cfg.stackColor,
            brightness: open ? cfg.brightness : cfg.brightness * 0.3,
            effect: open ? .breath : .solid,
            speed: cfg.speed
        )
    }

    /// The tab-cycle key's thread. Dimly lit whenever the bridge runs, for the
    /// same reason as the stack key: a bound-but-dark key reads as broken.
    public static func tabCycleThread(_ cfg: BridgeConfig = BridgeConfig()) -> OAI.Thread {
        OAI.Thread(
            id: Pad.tabCycleKeyID,
            color: cfg.tabCycleColor,
            brightness: cfg.brightness * 0.3,
            effect: .solid,
            speed: cfg.speed
        )
    }

    /// The land key's thread — the stack key's pattern: dim while idle so a
    /// bound key never reads as broken, breathing while its window is up.
    public static func landThread(
        open: Bool,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        OAI.Thread(
            id: Pad.landKeyID,
            color: cfg.landColor,
            brightness: open ? cfg.brightness : cfg.brightness * 0.3,
            effect: open ? .breath : .solid,
            speed: cfg.speed
        )
    }

    /// One half of the voice key — the callers paint both matrix positions
    /// identically so the single wide keycap reads as one light. Purple:
    /// steady while waiting for input, a slow breath while listening and a
    /// fast one while the take is processed.
    public static func voiceThread(
        id: Int,
        state: VoiceState = .waiting,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: cfg.voiceColor,
            brightness: cfg.brightness,
            effect: state == .waiting ? .solid : .breath,
            speed: state == .processing ? cfg.voiceProcessingSpeed : cfg.voiceListeningSpeed
        )
    }

    /// A key that sends a keystroke. The return key is always dark - the
    /// pad wears a black cover over it - and any other action is as quiet as
    /// a macro.
    public static func actionThread(
        id: Int,
        action: KeyBindings.Action,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        guard action == .enter else { return macroThread(id: id, cfg) }
        return OAI.Thread(id: id, brightness: 0, effect: .off)
    }

    /// A text-macro key's thread: dimly lit so it reads as bound, in a colour
    /// that stays out of the status conversation.
    public static func macroThread(id: Int, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: cfg.macroColor,
            brightness: cfg.brightness * 0.25,
            effect: .solid,
            speed: cfg.speed
        )
    }

    /// The underglow zone for an aggregate state, or nil to switch it off.
    public static func zone(for state: String?, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Zone? {
        guard let state, cfg.effect(for: state) != .off else { return nil }
        return OAI.Zone(
            effect: cfg.zoneEffects[state] ?? cfg.effect(for: state),
            brightness: cfg.brightness(for: state),
            speed: cfg.speed(for: state),
            magic: 1,
            color: cfg.color(for: state)
        )
    }
}
