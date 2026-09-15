import XCTest
@testable import WLKit

/// Uses a real keymap read off a device, so the double-encoded envelope and the
/// layer layout are exercised against genuine data rather than a fixture I
/// invented to match my own parser. It is the stock F-key map, straight from
/// `fs.read` — keep it that way, because half these tests assert on what an
/// *unmodified* device looks like.
final class KeymapManagerTests: XCTestCase {

    private func backupKeymap() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WLKitTests
            .appendingPathComponent("Fixtures/stock-keymap.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try KeymapManager.parse(raw)
    }

    func testParsesTheDoubleEncodedEnvelope() throws {
        let config = try backupKeymap()
        XCTAssertNotNil(config["profiles"], "inner JSON string must be decoded")
    }

    func testStockKeymapIsNotAgentBound() throws {
        let config = try backupKeymap()
        XCTAssertFalse(
            KeymapManager.isAgentKeymapApplied(config),
            "the backup is the stock F-key map"
        )
        XCTAssertEqual(KeymapManager.activeLayerKeymap(config)?[0], ["KC_F13", "KC_F14"])
    }

    /// The pad reports which layer it is on; the codes have to land there and
    /// nowhere else, or a pad on layer 2 keeps its stock keys while every
    /// write answers ok.
    func testApplyingTargetsTheRequestedLayerOnly() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config, layer: 1)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next, layer: 1))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(next, layer: 0),
                       "layer 1 stays the stock map")
        XCTAssertEqual(KeymapManager.activeLayerKeymap(next, layer: 0),
                       KeymapManager.activeLayerKeymap(config, layer: 0))
    }

    /// The spare layers have no joystick sectors, so the stick has to be
    /// given its four cardinals there, with the angles layer 1 uses.
    func testApplyingSeedsJoystickSectorsOnABareLayer() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config, layer: 1)
        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next, layer: 1))
        let joystick = try XCTUnwrap(layout["joystick"] as? [String: Any])
        let sectors = try XCTUnwrap(joystick["sectors"] as? [[String: Any]])
        XCTAssertEqual(sectors.count, 4)
        XCTAssertEqual(Set(sectors.compactMap { $0["k"] as? String }),
                       ["KV_OAI_AG15", "KV_OAI_AG16", "KV_OAI_AG17", "KV_OAI_AG18"])
        let north = try XCTUnwrap(sectors.first { $0["k"] as? String == "KV_OAI_AG15" })
        XCTAssertEqual(north["a1"] as? Double, 0.1875, "geometry borrowed from layer 1")
        XCTAssertEqual(north["a2"] as? Double, 0.3125)
        XCTAssertEqual(joystick["type"] as? String, "JOYSTICK", "the rest of the object is untouched")
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next, layer: 1))
    }

    /// A layer the file does not have falls back to the first rather than
    /// crashing or writing nowhere.
    func testOutOfRangeLayerFallsBackToTheFirst() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config, layer: 99)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next, layer: 0))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next, layer: 99))
    }

    /// The whole pad is managed now — every key must carry its own AG code,
    /// each key's code matching its index so lights and presses line up.
    func testApplyingBindsEveryKeyToItsOwnCode() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next))

        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(next))
        XCTAssertEqual(Set(Pad.boundKeyIDs).count, Pad.keyCount, "every key is managed")
        for key in Pad.boundKeyIDs {
            let at = try XCTUnwrap(Pad.position(of: key))
            XCTAssertEqual(keymap[at.row][at.column], KeymapManager.agCodes[key])
        }
    }

    /// A pad bound the old way — six agent keys, stack key still on its F-key —
    /// has to report as *not* applied, or the rebind never happens.
    func testAgentOnlyKeymapIsNotConsideredApplied() throws {
        var config = try backupKeymap()
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        var keymap = try XCTUnwrap(layout["keymap"] as? [[String]])
        keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"]
        keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"]
        layout["keymap"] = keymap
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles

        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(try KeymapManager.withAgentKeymap(config)))
    }

    /// The dial's rotations become AG codes; its press keeps its keycode.
    func testApplyingBindsTheDialButNotItsPress() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let original = try XCTUnwrap(KeymapManager.activeLayerLayout(config))
        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let dial = try XCTUnwrap((layout["encoders"] as? [[String]])?.first)
        let originalDial = try XCTUnwrap((original["encoders"] as? [[String]])?.first)
        XCTAssertEqual(dial[0], "KV_OAI_AG13")
        XCTAssertEqual(dial[1], "KV_OAI_AG14")
        XCTAssertEqual(dial[2], originalDial[2], "the press is not ours to take")
    }

    /// The joystick's four cardinal sectors become AG codes; diagonals keep
    /// whatever they had.
    func testApplyingBindsTheJoystickCardinals() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let joystick = try XCTUnwrap(layout["joystick"] as? [String: Any])
        let sectors = try XCTUnwrap(joystick["sectors"] as? [[String: Any]])

        var cardinals: [Double: String] = [:]
        var diagonals = 0
        for sector in sectors {
            let a1 = try XCTUnwrap(sector["a1"] as? Double)
            let a2 = try XCTUnwrap(sector["a2"] as? Double)
            let centre = KeymapManager.sectorCentre(a1, a2)
            if let code = sector["k"] as? String, code.hasPrefix("KV_OAI_AG") {
                cardinals[centre] = code
            } else {
                diagonals += 1
            }
        }
        XCTAssertEqual(cardinals[0.25], "KV_OAI_AG15")
        XCTAssertEqual(cardinals[0.50], "KV_OAI_AG16")
        XCTAssertEqual(cardinals[0.75], "KV_OAI_AG17")
        XCTAssertEqual(cardinals[0.00], "KV_OAI_AG18")
        XCTAssertEqual(diagonals, 4, "the diagonal sectors keep their keycodes")
    }

    func testApplyingIsIdempotent() throws {
        let once = try KeymapManager.withAgentKeymap(try backupKeymap())
        let twice = try KeymapManager.withAgentKeymap(once)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(twice))
    }

    func testEverythingElseSurvivesTheRewrite() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let profiles = try XCTUnwrap(next["profiles"] as? [[String: Any]])
        let layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 3, "the other layers are preserved")

        let layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        XCTAssertNotNil(layout["encoders"], "encoders survive")
        XCTAssertNotNil(layout["joystick"], "joystick survives")
        XCTAssertNotNil(layers[0]["lights"], "per-layer lighting survives")
    }

    func testMalformedInputIsRejectedRatherThanSilentlyAccepted() {
        XCTAssertThrowsError(try KeymapManager.parse(["nope": 1]))
        XCTAssertThrowsError(try KeymapManager.parse(["data": "not json"]))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied([:]))
    }
}
