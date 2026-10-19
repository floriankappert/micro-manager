import XCTest
import SwiftUI
@testable import WLKit

/// Mirrors test/status.test.js so the two implementations cannot drift.
final class StatusMapperTests: XCTestCase {

    private func agent(_ status: String, pane: String = "w1:p1") -> HerdrAgent {
        HerdrAgent(status: status, paneID: pane)
    }

    // MARK: - Aggregate

    func testNoAgentsMeansNoState() {
        XCTAssertNil(StatusMapper.aggregate([]))
    }

    func testBlockedOutranksWorkingAndIdle() {
        let state = StatusMapper.aggregate([
            agent("idle", pane: "w1:p1"),
            agent("working", pane: "w1:p2"),
            agent("blocked", pane: "w1:p3"),
        ])
        XCTAssertEqual(state, "blocked")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0xFF2D2D)
    }

    func testWorkingOutranksIdleAndDone() {
        let state = StatusMapper.aggregate([agent("done"), agent("idle"), agent("working")])
        XCTAssertEqual(state, "working")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0xFF6A00)
    }

    func testUnrecognisedStatusStillYieldsAState() {
        XCTAssertEqual(StatusMapper.aggregate([agent("wat")]), "unknown")
    }

    func testBlockedAndWorkingBreatheAtDifferentPaces() {
        XCTAssertEqual(StatusMapper.zone(for: "blocked")?.effect, .breath)
        XCTAssertEqual(StatusMapper.threads(for: [agent("working")])[0].effect, .breath)
    }

    func testUnderglowStaysSteadyWhileWorking() {
        XCTAssertEqual(StatusMapper.zone(for: "working")?.effect, .solid)
        XCTAssertEqual(StatusMapper.zone(for: "working")?.color, 0xFF6A00)
        XCTAssertEqual(StatusMapper.zone(for: "blocked")?.effect, .breath)
    }

    // MARK: - Per-key

    func testEachAgentGetsItsOwnKeyInReadingOrder() {
        let threads = StatusMapper.threads(for: [
            agent("working"), agent("blocked"), agent("idle"),
        ])
        XCTAssertEqual(threads.count, 6, "one entry per agent key")
        // The pad's top row is wired right to left, so reading order starts
        // at key 1: the first agent lights the top-LEFT key.
        XCTAssertEqual(threads.map(\.id), [1, 0, 2, 3, 4, 5], "keys in reading order")
        XCTAssertEqual(threads[0].color, 0xFF6A00)
        XCTAssertEqual(threads[1].color, 0xFF2D2D)
        XCTAssertEqual(threads[2].effect, .off, "idle is dark")
    }

    func testKeysWithNoAgentAreSwitchedOffNotLeftStale() {
        let threads = StatusMapper.threads(for: [agent("working")])
        for thread in threads.dropFirst() {
            XCTAssertEqual(thread.effect, .off)
            XCTAssertEqual(thread.brightness, 0)
            XCTAssertNil(thread.color, "no colour on an unused key")
        }
    }

    func testBlockedAgentBreathesFasterOnItsOwnKey() {
        let threads = StatusMapper.threads(for: [agent("working"), agent("blocked")])
        XCTAssertEqual(threads[0].effect, .breath)
        XCTAssertEqual(threads[1].effect, .breath)
        XCTAssertGreaterThan(threads[1].speed ?? 0, threads[0].speed ?? 0)
    }

    func testMoreAgentsThanKeysDoesNotOverflow() {
        let many = (0..<9).map { _ in agent("working") }
        XCTAssertEqual(StatusMapper.threads(for: many).count, 6)
    }

    func testConfigOverridesAreHonoured() throws {
        var cfg = BridgeConfig()
        cfg.colors["working"] = 0x123456
        cfg.brightness = 0.3
        let thread = StatusMapper.threads(for: [agent("working")], cfg)[0]
        XCTAssertEqual(thread.color, 0x123456)
        XCTAssertEqual(try XCTUnwrap(thread.brightness), 0.3 * 0.8, accuracy: 1e-9)
    }

    // MARK: - Wire encoding

    func testThreadWireUsesAbbreviatedKeysAndNumericEffect() {
        let wire = OAI.Thread(id: 0, color: 0xFF0000, brightness: 1, effect: .solid, speed: 0.5).wire
        XCTAssertEqual(wire["id"] as? Int, 0)
        XCTAssertEqual(wire["c"] as? Int, 0xFF0000)
        XCTAssertEqual(wire["b"] as? Double, 1)
        XCTAssertEqual(wire["e"] as? Int, 1, "effect is a NUMBER, not a string")
        XCTAssertEqual(wire["s"] as? Double, 0.5)
        XCTAssertNil(wire["color"], "full field names are ignored by the firmware")
    }

    func testUnsetThreadFieldsAreOmittedSoTheyStayUnchanged() {
        let wire = OAI.Thread(id: 3, brightness: 0, effect: .off).wire
        XCTAssertNil(wire["c"])
        XCTAssertNil(wire["s"])
    }

    func testColourRoundTrip() {
        XCTAssertEqual(packedRGB(fromHex: "#FF2D2D"), 0xFF2D2D)
        XCTAssertEqual(packedRGB(fromHex: "00C853"), 0x00C853)
        XCTAssertEqual(packedRGB(fromHex: "#0f0"), 0x00FF00)
        XCTAssertEqual(hexString(0xFF2D2D), "#FF2D2D")
    }

    /// Slots follow the pad's reading order, so a slot must always resolve to
    /// the key that lights it and back.
    func testAgentSlotAndKeyAreInverses() {
        for (slot, key) in Pad.agentKeyIDs.enumerated() {
            XCTAssertEqual(Pad.agentSlot(for: key), slot)
        }
        XCTAssertNil(Pad.agentSlot(for: Pad.stackKeyID))
        XCTAssertNil(Pad.agentSlot(for: Pad.landKeyID))
    }

    // MARK: - AG key names

    func testAGNamesMapToKeyIndices() {
        XCTAssertEqual(OAI.agIndex("AG00"), 0)
        XCTAssertEqual(OAI.agIndex("AG05"), 5)
        XCTAssertEqual(OAI.agIndex("AG12"), 12)
        XCTAssertNil(OAI.agIndex("KC_F13"))
        XCTAssertNil(OAI.agIndex(nil))
    }
}

// MARK: - Status colours must stay distinguishable

extension StatusMapperTests {

    func testDoneIsLitAndIdleIsDark() {
        // "done" means finished and not yet looked at; "idle" means finished
        // and seen. Different signals: one is lit, the other is dark.
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "done"), 0x00C853)
        XCTAssertEqual(cfg.effect(for: "done"), .breath)
        XCTAssertEqual(cfg.effect(for: "idle"), .off)
        XCTAssertEqual(cfg.brightness(for: "idle"), 0)
        XCTAssertNil(StatusMapper.zone(for: "idle"))
    }

    func testLitStatesAllHaveDistinctColours() {
        let cfg = BridgeConfig()
        var seen: [Int: String] = [:]
        for state in ["blocked", "working", "done"] {
            let color = cfg.color(for: state)
            XCTAssertNil(seen[color], "\(state) reuses the colour of \(seen[color] ?? "")")
            seen[color] = state
        }
    }

    func testDoneAndIdleAgentsGetDifferentKeys() {
        let threads = StatusMapper.threads(for: [
            HerdrAgent(status: "done", paneID: "w1:p1"),
            HerdrAgent(status: "idle", paneID: "w1:p2"),
        ])
        XCTAssertEqual(threads[0].color, 0x00C853)
        XCTAssertEqual(threads[0].effect, .breath)
        XCTAssertEqual(threads[1].effect, .off)
        XCTAssertEqual(threads[1].brightness, 0)
    }

    /// Pins every lit status colour. A silent change to one is a bug you find
    /// by looking at hardware, the slowest possible way to find it.
    func testEveryStatusColourIsPinned() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "blocked"), 0xFF2D2D)
        XCTAssertEqual(cfg.color(for: "working"), 0xFF6A00)
        XCTAssertEqual(cfg.color(for: "done"), 0x00C853)
    }

    func testUnknownIsDarkAndLeavesTheUnderglowOff() {
        let threads = StatusMapper.threads(for: [agent("wat")])
        XCTAssertEqual(threads[0].effect, .off)
        XCTAssertEqual(threads[0].brightness, 0)
        XCTAssertNil(StatusMapper.zone(for: "unknown"))
    }

    func testCalmIsDarkAndAttentionBreathes() {
        let cfg = BridgeConfig()
        XCTAssertLessThan(cfg.brightness(for: "working"), cfg.brightness(for: "blocked"))
        XCTAssertEqual(cfg.effect(for: "blocked"), .breath)
        XCTAssertEqual(cfg.effect(for: "done"), .breath)
        XCTAssertLessThan(cfg.speed(for: "done"), cfg.speed(for: "blocked"))
    }
}

extension StatusMapperTests {

    func testVoiceKeyIsAlwaysRedAndBreathesOnlyWhileListening() {
        let rest = StatusMapper.voiceThread(id: 12, active: false)
        let listening = StatusMapper.voiceThread(id: 12, active: true)
        XCTAssertEqual(rest.color, 0xFF3B30)
        XCTAssertEqual(rest.effect, .solid)
        XCTAssertEqual(rest.brightness, BridgeConfig().brightness)
        XCTAssertEqual(listening.color, 0xFF3B30)
        XCTAssertEqual(listening.effect, .breath)
    }

    func testReturnKeyIsAlwaysDarkAndOtherActionsStayQuiet() {
        let enter = StatusMapper.actionThread(id: 10, action: .enter)
        XCTAssertEqual(enter.effect, .off)
        XCTAssertEqual(enter.brightness, 0)
        XCTAssertNil(enter.color)
        let back = StatusMapper.actionThread(id: 9, action: .backspace)
        XCTAssertEqual(back.color, BridgeConfig().macroColor)
    }
}

extension StatusMapperTests {

    private func date(hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour))!
    }

    func testNightDimsAndDayDoesNot() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.lit(at: date(hour: 12)).brightness, 1)
        XCTAssertEqual(cfg.lit(at: date(hour: 7)).brightness, 1, "night ends at 7")
        XCTAssertEqual(cfg.lit(at: date(hour: 22)).brightness, cfg.nightBrightness)
        XCTAssertEqual(cfg.lit(at: date(hour: 3)).brightness, cfg.nightBrightness)
    }

    func testNightBrightnessReachesEveryStatusKey() {
        let cfg = BridgeConfig().lit(at: date(hour: 2))
        let thread = StatusMapper.threads(for: [agent("blocked")], cfg)[0]
        XCTAssertEqual(thread.brightness, BridgeConfig().nightBrightness)
    }
}

extension StatusMapperTests {

    func testWorkingAgentsStartedAtDifferentTimesBreatheAtDifferentPaces() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let threads = StatusMapper.threads(
            for: [agent("working", pane: "a"), agent("working", pane: "b")],
            workingSince: [t0, t0.addingTimeInterval(3)])
        XCTAssertNotEqual(threads[0].speed, threads[1].speed)
        for thread in threads.prefix(2) {
            let ratio = (thread.speed ?? 0) / BridgeConfig().speed
            XCTAssertEqual(ratio, 1, accuracy: 0.1)
        }
    }

    func testBreathPaceIsStableForTheSameStart() {
        let t = Date(timeIntervalSinceReferenceDate: 4_242)
        XCTAssertEqual(StatusMapper.breathSpeed(base: 0.5, since: t),
                       StatusMapper.breathSpeed(base: 0.5, since: t))
    }
}

// MARK: - bhote review

extension StatusMapperTests {

    func testReviewTopicsMapToTheirPanesPerMachine() {
        let json = Data("""
        [{"status":"review","agent":{"machine":"Omarchy","pane":"w4:p1"}},
         {"status":"review","agent":{"machine":"Mac","pane":"w3:p2"}},
         {"status":"now","agent":{"machine":"Mac","pane":"wJ:p1"}},
         {"status":"review","agent":null}]
        """.utf8)
        XCTAssertEqual(
            BhoteReview.panes(from: json, remoteNames: ["omarchy"]).review,
            ["omarchy|w4:p1", "|w3:p2"])
    }

    func testIdleAgentInReviewBecomesReviewButWorkingStaysWorking() {
        let omarchy = HerdrHost(name: "omarchy", socketPath: "/x")
        let agents = [
            HerdrAgent(status: "idle", paneID: "w4:p1", host: omarchy),
            HerdrAgent(status: "working", paneID: "w3:p2"),
            HerdrAgent(status: "idle", paneID: "w4:p1"),
        ]
        let out = BhoteReview.resolve(agents, panes: .init(review: ["omarchy|w4:p1", "|w3:p2"]))
        XCTAssertEqual(out.map(\.status), ["review", "working", "idle"],
                       "pane ids repeat across machines, so the host decides")
    }

    func testReviewBreathesRedSlowerThanBlockedAndOutranksIdle() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "review"), 0x2979FF)
        XCTAssertEqual(cfg.effect(for: "review"), .breath)
        XCTAssertLessThan(cfg.speed(for: "review"), cfg.speed(for: "blocked"))
        XCTAssertEqual(StatusMapper.aggregate([agent("idle"), agent("review")]), "review")
    }

    func testMalformedBhoteOutputYieldsNothing() {
        XCTAssertTrue(BhoteReview.panes(from: Data("nope".utf8), remoteNames: []).isEmpty)
    }
}

extension StatusMapperTests {

    func testFinishedTopicsMakeIdleAgentsFinishedAndReviewWins() {
        let json = Data("""
        [{"status":"finished","agent":{"machine":"Mac","pane":"wJ:p1"}},
         {"status":"finished","agent":{"machine":"Mac","pane":"wK:p1"}},
         {"status":"review","agent":{"machine":"Mac","pane":"wK:p1"}}]
        """.utf8)
        let panes = BhoteReview.panes(from: json, remoteNames: [])
        XCTAssertEqual(panes.finished, ["|wJ:p1", "|wK:p1"])
        let out = BhoteReview.resolve([
            HerdrAgent(status: "idle", paneID: "wJ:p1"),
            HerdrAgent(status: "idle", paneID: "wK:p1"),
            HerdrAgent(status: "working", paneID: "wJ:p1"),
        ], panes: panes)
        XCTAssertEqual(out.map(\.status), ["finished", "review", "working"])
    }

    func testFinishedIsGreenAndQuickerThanDone() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "finished"), 0x00C853)
        XCTAssertEqual(cfg.effect(for: "finished"), .breath)
        XCTAssertGreaterThan(cfg.speed(for: "finished"), cfg.speed(for: "done"))
        XCTAssertEqual(StatusMapper.aggregate([agent("done"), agent("finished")]), "finished")
    }

    func testTestingTopicOverridesIdleAndDoneButNotWorking() {
        let json = #"[{"status":"testing","agent":{"machine":"Mac","pane":"wJ:p1"}}]"#.data(using: .utf8)!
        let panes = BhoteReview.panes(from: json, remoteNames: [])
        XCTAssertEqual(panes.testing, ["|wJ:p1"])
        let out = BhoteReview.resolve([
            HerdrAgent(status: "idle", paneID: "wJ:p1"),
            HerdrAgent(status: "done", paneID: "wJ:p1"),
            HerdrAgent(status: "working", paneID: "wJ:p1"),
        ], panes: panes)
        XCTAssertEqual(out.map(\.status), ["testing", "testing", "working"])
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "testing"), 0xFFB300)
        XCTAssertEqual(cfg.effect(for: "testing"), .breath)
    }

    func testOfflineAgentIsDimGreyWhateverItWasDoing() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "off-working"), 0x607080)
        XCTAssertEqual(cfg.effect(for: "off-blocked"), .solid)
        XCTAssertLessThan(cfg.brightness(for: "off-working"), cfg.brightness(for: "working"))
    }

    func testIdleAgentUnderANowTopicCountsAsFinishedLikeBhotesPanel() {
        let json = #"[{"status":"now","agent":{"machine":"Mac","pane":"wJ:p1"}}]"#.data(using: .utf8)!
        let panes = BhoteReview.panes(from: json, remoteNames: [])
        let out = BhoteReview.resolve([
            HerdrAgent(status: "idle", paneID: "wJ:p1"),
            HerdrAgent(status: "working", paneID: "wJ:p1"),
        ], panes: panes)
        XCTAssertEqual(out.map(\.status), ["finished", "working"])
    }
}
