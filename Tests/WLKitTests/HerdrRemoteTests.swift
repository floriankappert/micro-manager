import XCTest
@testable import WLKit

final class HerdrRemoteTests: XCTestCase {

    private func parse(_ json: String) -> [HerdrRemote] {
        HerdrRemote.parse(Data(json.utf8))
    }

    func testParsesEntriesAndShorthand() {
        let remotes = parse(#"{"remotes": [{"name": "omarchy", "ssh": "omarchy-flo"}, "box", {"ssh": "b", "socket": "/run/h.sock"}]}"#)
        XCTAssertEqual(remotes, [
            HerdrRemote(name: "omarchy", ssh: "omarchy-flo"),
            HerdrRemote(name: "box", ssh: "box"),
            HerdrRemote(name: "b", ssh: "b", socket: "/run/h.sock"),
        ])
    }

    func testSkipsBrokenAndDuplicateEntries() {
        let remotes = parse(#"{"remotes": [{"name": "x"}, {"name": "a/b", "ssh": "h"}, "dup", {"name": "dup", "ssh": "other"}, 3]}"#)
        XCTAssertEqual(remotes, [HerdrRemote(name: "dup", ssh: "dup")],
                       "no destination, a name that is not a file name, and a second 'dup' are all dropped")
        XCTAssertEqual(parse(#"{}"#), [])
    }

    func testPaneKeysDoNotCollideAcrossHosts() {
        let remote = HerdrHost(name: "omarchy", socketPath: "/tmp/x.sock")
        let here = HerdrAgent(status: "idle", paneID: "w1:p1")
        let there = HerdrAgent(status: "idle", paneID: "w1:p1", host: remote)
        XCTAssertNotEqual(here.paneKey, there.paneKey)
    }

    // MARK: - Merging servers

    func testLocalAgentsComeFirstAndCarryTheirHost() async throws {
        let a = try FakeHerdr(agents: [["pane_id": "w1:p1", "agent_status": "working"]])
        let b = try FakeHerdr(agents: [["pane_id": "w1:p1", "agent_status": "idle"],
                                       ["pane_id": "w2:p1", "agent_status": "done"]])
        defer { a.stop(); b.stop() }
        let here = HerdrHost(name: nil, socketPath: a.path)
        let there = HerdrHost(name: "omarchy", socketPath: b.path)

        let result = try await HerdrClient.listAllAgents(hosts: [here, there])
        XCTAssertEqual(result.agents.map(\.status), ["working", "idle", "done"])
        XCTAssertEqual(result.agents.map(\.host.name), [nil, "omarchy", "omarchy"])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testAnUnreachableRemoteDoesNotBlankTheLocalAgents() async throws {
        let a = try FakeHerdr(agents: [["pane_id": "w1:p1", "agent_status": "working"]])
        defer { a.stop() }
        let here = HerdrHost(name: nil, socketPath: a.path)
        let gone = HerdrHost(name: "omarchy", socketPath: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(8)).sock")

        let result = try await HerdrClient.listAllAgents(hosts: [here, gone])
        XCTAssertEqual(result.agents.count, 1)
        XCTAssertNotNil(result.failures[gone])
    }

    func testThrowsOnlyWhenNothingAnswers() async {
        let gone = HerdrHost(name: nil, socketPath: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(8)).sock")
        do {
            _ = try await HerdrClient.listAllAgents(hosts: [gone])
            XCTFail("expected a throw")
        } catch {}
    }
}

/// Answers every connection's request with a fixed `agent.list`, the one
/// request per connection the real server allows.
private final class FakeHerdr: @unchecked Sendable {
    let path: String
    private let fd: Int32

    init(agents: [[String: Any]]) throws {
        path = NSTemporaryDirectory() + "herdr-\(UUID().uuidString.prefix(8)).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw HerdrError.cannotConnect(path, "bind") }

        let body = try JSONSerialization.data(withJSONObject: ["id": "x", "result": ["agents": agents]])
        let reply = body + Data("\n".utf8)
        let listener = fd
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &buffer, buffer.count)
                reply.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    func stop() {
        close(fd)
        unlink(path)
    }
}
