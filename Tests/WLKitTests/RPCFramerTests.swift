import XCTest
@testable import WLKit

final class RPCFramerTests: XCTestCase {

    private func strings(_ messages: [Data]) -> [String] {
        messages.map { String(decoding: $0, as: UTF8.self) }
    }

    func testReassemblesAcrossFragments() {
        var framer = RPCFramer()
        XCTAssertEqual(framer.feed(Array(#"{"id":1,"res"#.utf8), at: 0), [])
        XCTAssertEqual(strings(framer.feed(Array(#"ult":{"ok":1}}"#.utf8), at: 0.01)),
                       [#"{"id":1,"result":{"ok":1}}"#])
        XCTAssertTrue(framer.buffer.isEmpty)
    }

    func testSeveralMessagesInOneFragment() {
        var framer = RPCFramer()
        let out = strings(framer.feed(Array(#"{"id":1}{"m":"x","p":{"k":"}"}}"#.utf8), at: 0))
        XCTAssertEqual(out, [#"{"id":1}"#, #"{"m":"x","p":{"k":"}"}}"#], "a brace inside a string is not structure")
    }

    /// The failure that made the pad go deaf: the fragment carrying the closing
    /// braces never arrives. Without a resync every later message nests inside
    /// the broken one and nothing is ever delivered.
    func testLostFragmentResyncsOnTheNextMessage() {
        var framer = RPCFramer()
        _ = framer.feed(Array(#"{"id":1,"result":{"la"#.utf8), at: 0)
        // ...the rest of message 1 is lost. A key press arrives a second later.
        let out = strings(framer.feed(Array(#"{"m":"v.oai.hid","p":{"k":"AG03","act":1}}"#.utf8), at: 1.0))
        XCTAssertEqual(out, [#"{"m":"v.oai.hid","p":{"k":"AG03","act":1}}"#])
        XCTAssertEqual(framer.resyncs, 1)
    }

    func testFragmentsInQuickSuccessionAreNotMistakenForSilence() {
        var framer = RPCFramer()
        _ = framer.feed(Array(#"{"id":2,"#.utf8), at: 0)
        _ = framer.feed(Array(#""result":"#.utf8), at: 0.03)
        XCTAssertEqual(strings(framer.feed(Array(#"{}}"#.utf8), at: 0.06)), [#"{"id":2,"result":{}}"#])
        XCTAssertEqual(framer.resyncs, 0)
    }

    func testMultiByteCharacterSplitAcrossFragments() {
        var framer = RPCFramer()
        let bytes = Array(#"{"name":"Kräfte"}"#.utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1   // between the two bytes of "ä"
        XCTAssertEqual(framer.feed(Array(bytes[..<split]), at: 0), [])
        XCTAssertEqual(strings(framer.feed(Array(bytes[split...]), at: 0.01)), [#"{"name":"Kräfte"}"#])
    }

    func testJunkBetweenMessagesIsDropped() {
        var framer = RPCFramer()
        XCTAssertEqual(framer.feed(Array("\r\n}".utf8), at: 0), [])
        XCTAssertTrue(framer.buffer.isEmpty)
        XCTAssertEqual(strings(framer.feed(Array(#"{"id":3}"#.utf8), at: 5)), [#"{"id":3}"#])
        XCTAssertEqual(framer.resyncs, 0, "nothing was in flight, so nothing was dropped")
    }

    func testOverflowIsBounded() {
        var framer = RPCFramer()
        framer.capacity = 16
        _ = framer.feed(Array(#"{"a":"0123456789abcdef"#.utf8), at: 0)
        XCTAssertTrue(framer.buffer.isEmpty)
    }
}
