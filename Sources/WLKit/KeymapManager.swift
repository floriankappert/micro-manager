import Foundation

/// Device keymap handling.
///
/// Per-key lighting only works on keys bound to `KV_OAI_AG*` keycodes, and only
/// when those bindings are on the ACTIVE layer — parking them on a spare layer
/// does nothing. Nothing reports a mismatch: `v.oai.thstatus` still answers
/// `{"ok":1}` for a key it cannot light, so a wrong keymap looks exactly like a
/// working one from the host side. Hence checking rather than assuming.
///
/// The file itself is double-encoded: `fs.read` returns `{"data": "<json>"}`
/// where the inner string is the real config.
public enum KeymapManager {

    /// Indexed by key: key N is bound to `agCodes[N]`.
    public static let agCodes = [
        "KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02",
        "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05",
        "KV_OAI_AG06", "KV_OAI_AG07", "KV_OAI_AG08",
        "KV_OAI_AG09", "KV_OAI_AG10", "KV_OAI_AG11",
        "KV_OAI_AG12",
    ]

    /// The dial: clockwise, counter-clockwise. Its press keeps whatever it
    /// already does — that click is not this app's to take.
    static let dialCodes = ["KV_OAI_AG13", "KV_OAI_AG14"]

    /// The joystick's four cardinal sectors, matched by the angle at their
    /// centre in the radial map. Diagonal sectors are left alone.
    static let joystickCodes: [(centre: Double, code: String)] = [
        (0.25, "KV_OAI_AG15"),
        (0.50, "KV_OAI_AG16"),
        (0.75, "KV_OAI_AG17"),
        (0.00, "KV_OAI_AG18"),
    ]

    /// A sector's centre angle, handling the one that wraps through zero.
    static func sectorCentre(_ a1: Double, _ a2: Double) -> Double {
        let centre = a2 >= a1 ? (a1 + a2) / 2 : ((a1 + a2 + 1) / 2)
        return centre.truncatingRemainder(dividingBy: 1)
    }

    /// Four cardinal sectors for a layer that has none. The angles come from
    /// the first layer that defines sectors at those centres, so the stick
    /// keeps the dead zones the firmware was set up with; a file with no
    /// sectors anywhere gets quarter turns centred on the cardinals.
    static func cardinalSectors(from layers: [[String: Any]]) -> [[String: Any]] {
        let existing = layers
            .compactMap { ($0["layout"] as? [String: Any])?["joystick"] as? [String: Any] }
            .compactMap { $0["sectors"] as? [[String: Any]] }
            .first { !$0.isEmpty } ?? []
        return joystickCodes.map { target in
            let match = existing.first { sector in
                guard let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double
                else { return false }
                return abs(sectorCentre(a1, a2) - target.centre) < 0.01
            }
            if var sector = match {
                sector["k"] = target.code
                return sector
            }
            let a1 = (target.centre - 0.125 + 1).truncatingRemainder(dividingBy: 1)
            let a2 = (target.centre + 0.125).truncatingRemainder(dividingBy: 1)
            return ["a1": a1, "a2": a2, "k": target.code]
        }
    }

    /// The keycode each managed key must carry, addressed by its position in
    /// the [2, 4, 4, 3] matrix. Bindings are per key rather than per row: the
    /// stack key shares row 2 with three keys this app has no business
    /// touching, and rewriting the row would take their keycodes with it.
    static var bindings: [(row: Int, column: Int, code: String)] {
        Pad.boundKeyIDs.compactMap { key in
            guard key < agCodes.count, let at = Pad.position(of: key) else { return nil }
            return (at.row, at.column, agCodes[key])
        }
    }

    public enum Failure: LocalizedError {
        case noProfiles
        case notAccepted
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noProfiles: return "Device keymap has no profiles."
            case .notAccepted: return "The device did not accept the agent keymap."
            case .unreadable(let detail): return "Could not read the device keymap: \(detail)"
            }
        }
    }

    // MARK: - Parsing

    /// Unwraps the `{"data": "<json string>"}` envelope.
    public static func parse(_ raw: Any?) throws -> [String: Any] {
        guard let dict = raw as? [String: Any] else {
            throw Failure.unreadable("unexpected response shape")
        }
        guard let inner = dict["data"] as? String,
              let data = inner.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unreadable("missing or malformed `data` field")
        }
        return config
    }

    /// Which layer of the active profile the pad is actually on, 0-based.
    ///
    /// The keymap file does not say: `activeProfileId` picks the profile, but
    /// the layer is runtime state the pad reports as `layer_index` in
    /// `device.status`, 1-based. A pad left on its second layer - which is
    /// where at least one Bluetooth pad sits - ignores everything written to
    /// the first: no key reports, no per-key colours, and every write still
    /// answers ok. Unreadable status means layer 1, as before.
    /// nil when the pad did not answer, which is not the same as layer 1:
    /// guessing here is what parks the keycodes on a layer nobody is on.
    public static func activeLayer(_ device: WLDevice) async -> Int? {
        guard let status = try? await device.callAsync("device.status"),
              let dict = status as? [String: Any],
              let index = dict["layer_index"] as? Int
        else { return nil }
        return max(0, index - 1)
    }

    /// The layers of the active profile, or nil when the file has none.
    private static func layers(_ config: [String: Any]) -> [[String: Any]]? {
        let index = config["activeProfileId"] as? Int ?? 0
        guard let profiles = config["profiles"] as? [[String: Any]] else { return nil }
        let profile = index < profiles.count ? profiles[index] : profiles.first
        return profile?["layers"] as? [[String: Any]]
    }

    /// A layer that is out of range falls back to the first, so a stale
    /// status cannot send the keys into a layer that does not exist.
    private static func clamp(_ layer: Int, in layers: [[String: Any]]) -> Int {
        layer < layers.count ? layer : 0
    }

    static func activeLayerKeymap(_ config: [String: Any], layer: Int = 0) -> [[String]]? {
        activeLayerLayout(config, layer: layer)?["keymap"] as? [[String]]
    }

    static func activeLayerLayout(_ config: [String: Any], layer: Int = 0) -> [String: Any]? {
        guard let layers = layers(config), !layers.isEmpty else { return nil }
        return layers[clamp(layer, in: layers)]["layout"] as? [String: Any]
    }

    /// True when every managed key, the dial and the joystick's cardinal
    /// sectors carry their AG codes on the given layer of the active profile.
    public static func isAgentKeymapApplied(_ config: [String: Any], layer: Int = 0) -> Bool {
        guard let keymap = activeLayerKeymap(config, layer: layer) else { return false }
        for binding in bindings {
            guard binding.row < keymap.count,
                  binding.column < keymap[binding.row].count,
                  keymap[binding.row][binding.column] == binding.code
            else { return false }
        }

        guard let layout = activeLayerLayout(config, layer: layer) else { return false }
        if let encoders = layout["encoders"] as? [[String]], let dial = encoders.first {
            guard dial.count >= 2, dial[0] == dialCodes[0], dial[1] == dialCodes[1] else {
                return false
            }
        }
        if let joystick = layout["joystick"] as? [String: Any],
           let sectors = joystick["sectors"] as? [[String: Any]] {
            for (centre, code) in joystickCodes {
                let bound = sectors.contains { sector in
                    guard let a1 = sector["a1"] as? Double,
                          let a2 = sector["a2"] as? Double
                    else { return false }
                    return abs(sectorCentre(a1, a2) - centre) < 0.01
                        && sector["k"] as? String == code
                }
                if !bound { return false }
            }
        }
        return true
    }

    /// Rebinds the managed keys on one layer of the active profile, leaving
    /// every other key, layer, encoder, joystick and lighting setting untouched.
    public static func withAgentKeymap(_ config: [String: Any], layer target: Int = 0) throws -> [String: Any] {
        var next = config
        let index = next["activeProfileId"] as? Int ?? 0
        guard var profiles = next["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw Failure.noProfiles
        }
        let profileIndex = index < profiles.count ? index : 0
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty else {
            throw Failure.noProfiles
        }
        let layerIndex = clamp(target, in: layers)
        var layer = layers[layerIndex]
        guard var layout = layer["layout"] as? [String: Any],
              var keymap = layout["keymap"] as? [[String]]
        else { throw Failure.noProfiles }

        for binding in bindings
        where binding.row < keymap.count && binding.column < keymap[binding.row].count {
            keymap[binding.row][binding.column] = binding.code
        }

        // The dial's two rotation slots; its press stays untouched.
        if var encoders = layout["encoders"] as? [[String]],
           var dial = encoders.first, dial.count >= 2 {
            dial[0] = dialCodes[0]
            dial[1] = dialCodes[1]
            encoders[0] = dial
            layout["encoders"] = encoders
        }

        // The joystick's cardinal sectors; diagonals keep their keycodes.
        if var joystick = layout["joystick"] as? [String: Any] {
            var sectors = joystick["sectors"] as? [[String: Any]] ?? []
            // A spare layer ships with no sectors at all - the stock file has
            // eight on layer 1 and none on the others - and rewriting nothing
            // leaves the stick mute. Seed the four cardinals, borrowing the
            // geometry of a layer that has them so the pad sees the shape it
            // already knows; failing that, four quarter-turn sectors.
            if sectors.isEmpty {
                sectors = cardinalSectors(from: layers)
            }
            for index in sectors.indices {
                guard let a1 = sectors[index]["a1"] as? Double,
                      let a2 = sectors[index]["a2"] as? Double
                else { continue }
                let centre = sectorCentre(a1, a2)
                if let match = joystickCodes.first(where: { abs($0.centre - centre) < 0.01 }) {
                    sectors[index]["k"] = match.code
                }
            }
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }

        layout["keymap"] = keymap
        layer["layout"] = layout
        layers[layerIndex] = layer
        profile["layers"] = layers
        profiles[profileIndex] = profile
        next["profiles"] = profiles
        return next
    }

    // MARK: - Device I/O

    public static func read(_ device: WLDevice) async throws -> [String: Any] {
        let raw = try await device.callAsync("fs.read", params: ["file": "keymap.json"])
        return try parse(raw)
    }

    /// Rebinds the layer the pad is currently on. Returns true when it had to
    /// change something.
    @discardableResult
    public static func apply(_ device: WLDevice) async throws -> Bool {
        guard let layer = await activeLayer(device) else {
            throw Failure.unreadable("device.status reported no layer_index")
        }
        return try await apply(device, layer: layer)
    }

    /// Rebinds a known layer, for callers that already asked the pad which one
    /// it is on and would otherwise ask twice.
    @discardableResult
    public static func apply(_ device: WLDevice, layer: Int) async throws -> Bool {
        let config = try await read(device)
        if isAgentKeymapApplied(config, layer: layer) { return false }

        let next = try withAgentKeymap(config, layer: layer)
        let encoded = try JSONSerialization.data(withJSONObject: next)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw Failure.unreadable("could not encode keymap")
        }
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": text])

        let after = try await read(device)
        guard isAgentKeymapApplied(after, layer: layer) else { throw Failure.notAccepted }
        return true
    }
}
