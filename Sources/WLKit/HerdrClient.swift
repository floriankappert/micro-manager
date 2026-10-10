import Foundation

/// Client for the Herdr socket API: newline-delimited JSON over a Unix socket.
///
/// The server handles **exactly one request per connection** and then closes,
/// with one exception: `events.subscribe` takes over the stream and pushes
/// events until the client disconnects. So a request opens a short-lived
/// connection, and each subscription owns a dedicated long-lived one. A client
/// that reuses a connection for a second request simply never hears back.

/// A Herdr server to talk to: the one on this Mac, or one on another machine
/// reached through an SSH tunnel (see `HerdrTunnel`). The protocol is the same
/// either way; only the socket differs.
public struct HerdrHost: Hashable, Sendable {
    /// Nil for this Mac; otherwise the name the config gives the remote.
    public var name: String?
    public var socketPath: String

    public init(name: String?, socketPath: String) {
        self.name = name
        self.socketPath = socketPath
    }

    public static var local: HerdrHost { HerdrHost(name: nil, socketPath: HerdrClient.socketPath()) }
    public var isLocal: Bool { name == nil }
}

/// Which Herdr servers the app knows, and which one the person is working in.
///
/// Every server has its own focused agent, so "the focused agent" - what the
/// dial tunes, what a macro types into - needs a host to ask. That is the one
/// the pad last jumped to, starting on this Mac.
public final class HerdrHosts: @unchecked Sendable {
    public static let shared = HerdrHosts()

    private let lock = NSLock()
    private var _remotes: [HerdrHost] = []
    private var _active: HerdrHost?

    /// This Mac first, then the remotes in config order - the order agents
    /// fill the keys in.
    public var all: [HerdrHost] { [.local] + remotes }

    public var remotes: [HerdrHost] {
        get { lock.lock(); defer { lock.unlock() }; return _remotes }
        set {
            lock.lock(); defer { lock.unlock() }
            _remotes = newValue
            if let active = _active, !newValue.contains(active) { _active = nil }
        }
    }

    public var active: HerdrHost {
        get { lock.lock(); defer { lock.unlock() }; return _active ?? .local }
        set { lock.lock(); defer { lock.unlock() }; _active = newValue.isLocal ? nil : newValue }
    }
}

public struct HerdrAgent: Equatable, Sendable {
    /// The server this agent runs under. Pane and tab ids are only unique
    /// within one server - two machines both have a "w1:p1" - so anything
    /// keyed by them has to carry this too.
    public var host: HerdrHost = .local
    public var terminalID: String?
    public var paneID: String?
    public var tabID: String?
    public var workspaceID: String?
    public var agent: String
    public var status: String
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool

    /// The target to hand to `agent.focus`, which resolves **pane ids only**:
    /// a `terminal_id` comes back as `agent_not_found` (Herdr 0.7.5). Herdr
    /// reports a terminal id for every agent, so preferring it here meant every
    /// jump failed while the read-only paths — which never call `agent.focus` —
    /// kept working. Terminal id stays as a fallback for a Herdr that omits
    /// `pane_id`.
    public var focusTarget: String? { paneID ?? terminalID }

    /// Where the agent is actually working. `foreground_cwd` follows a `cd`
    /// inside the pane; `cwd` is only where the pane started.
    public var workingDirectory: String? {
        [foregroundCwd, cwd].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Identifies the pane across every server.
    public var paneKey: String? {
        paneID.map { "\(host.name ?? "")|\($0)" }
    }

    /// Last path component of the working directory, which is what a person
    /// recognises the agent by.
    public var shortName: String {
        guard let directory = workingDirectory else { return agent }
        return (directory as NSString).lastPathComponent
    }

    init(json: [String: Any], host: HerdrHost = .local) {
        self.host = host
        terminalID = json["terminal_id"] as? String
        paneID = json["pane_id"] as? String
        tabID = json["tab_id"] as? String
        workspaceID = json["workspace_id"] as? String
        agent = json["agent"] as? String ?? "agent"
        status = json["agent_status"] as? String ?? "unknown"
        cwd = json["cwd"] as? String
        foregroundCwd = json["foreground_cwd"] as? String
        focused = json["focused"] as? Bool ?? false
    }

    /// For tests.
    public init(
        agent: String = "claude",
        status: String,
        paneID: String? = nil,
        tabID: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil,
        focused: Bool = false,
        host: HerdrHost = .local
    ) {
        self.host = host
        self.agent = agent
        self.status = status
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
    }

}

public struct HerdrTab: Equatable, Sendable {
    public var tabID: String
    public var workspaceID: String
    /// Display position within the workspace, which is the order tabs cycle in.
    public var number: Int
    public var focused: Bool

    init(json: [String: Any]) {
        tabID = json["tab_id"] as? String ?? ""
        workspaceID = json["workspace_id"] as? String ?? ""
        number = json["number"] as? Int ?? 0
        focused = json["focused"] as? Bool ?? false
    }

    /// For tests.
    public init(tabID: String, workspaceID: String = "ws", number: Int, focused: Bool = false) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.number = number
        self.focused = focused
    }
}

public enum HerdrError: LocalizedError {
    case cannotConnect(String, String)
    case timeout(String)
    case api(String)
    case closed(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConnect(let path, let reason):
            return "Cannot reach the Herdr server at \(path): \(reason)"
        case .timeout(let method): return "Timed out waiting for \(method)."
        case .api(let message): return message
        case .closed(let method): return "Connection closed before \(method) responded."
        case .badResponse(let detail): return "Bad response: \(detail)"
        }
    }
}

public enum HerdrClient {

    public static func socketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["HERDR_SOCKET_PATH"], !explicit.isEmpty { return explicit }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("herdr/herdr.sock")
    }

    // MARK: - Requests

    public static func request(
        _ method: String,
        params: [String: Any] = [:],
        on host: HerdrHost = .local,
        timeout: TimeInterval = 5
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let conn = SocketConnection(path: host.socketPath)
            var finished = false
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                conn.close()
                continuation.resume(with: result)
            }

            conn.onLine = { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    finish(.failure(HerdrError.badResponse(line)))
                    return
                }
                if let error = object["error"] as? [String: Any] {
                    finish(.failure(HerdrError.api(error["message"] as? String ?? "api error")))
                } else {
                    finish(.success(object["result"] as? [String: Any] ?? [:]))
                }
            }
            conn.onClosed = { error in
                finish(.failure(error ?? HerdrError.closed(method)))
            }

            do {
                try conn.open()
            } catch {
                finish(.failure(error))
                return
            }

            let envelope: [String: Any] = ["id": nextID(), "method": method, "params": params]
            guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
                finish(.failure(HerdrError.badResponse("could not encode params")))
                return
            }
            conn.write(payload + Data("\n".utf8))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HerdrError.timeout(method)))
            }
        }
    }

    /// Agents in the server's own order — workspace, then tab, then pane —
    /// which is exactly how Herdr's agent panel lists them in grouped mode.
    /// Slot N is element N, so the pad reads like the sidebar. Do not re-sort:
    /// an earlier version ordered by ID strings here, and IDs do not sort the
    /// way the sidebar displays.
    public static func listAgents(on host: HerdrHost = .local, timeout: TimeInterval = 5) async throws -> [HerdrAgent] {
        let result = try await request("agent.list", on: host, timeout: timeout)
        let raw = result["agents"] as? [[String: Any]] ?? []
        return raw.map { HerdrAgent(json: $0, host: host) }
    }

    /// Every server's agents, this Mac's first, each server in its own order.
    ///
    /// A remote that cannot be reached is left out and reported, not thrown:
    /// a sleeping laptop across the room must not blank the keys of the agents
    /// on this one. Only a failure of this Mac's own server throws, and only
    /// when no remote answered either.
    public static func listAllAgents(
        hosts: [HerdrHost] = HerdrHosts.shared.all
    ) async throws -> (agents: [HerdrAgent], failures: [HerdrHost: Error]) {
        let results = await withTaskGroup(of: (Int, Result<[HerdrAgent], Error>).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    // A remote gets less patience: a stalled tunnel would
                    // otherwise hold up the lights for the local agents.
                    do { return (index, .success(try await listAgents(on: host, timeout: host.isLocal ? 5 : 3))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<[HerdrAgent], Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var agents: [HerdrAgent] = []
        var failures: [HerdrHost: Error] = [:]
        for (host, result) in zip(hosts, results) {
            switch result {
            case .success(let list): agents += list
            case .failure(let error): failures[host] = error
            }
        }
        if let error = failures[.local] ?? failures.values.first, failures.count == hosts.count {
            throw error
        }
        return (agents, failures)
    }

    /// The agent whose pane has focus in Herdr, if any. Fetched fresh rather
    /// than read off the bridge's poll, since focus is exactly the thing that
    /// changes between polls.
    ///
    /// With remotes configured, every server has a focused agent of its own;
    /// this asks the one the pad last jumped to (`HerdrHosts.active`).
    public static func focusedAgent() async throws -> HerdrAgent? {
        try await listAgents(on: HerdrHosts.shared.active).first(where: \.focused)
    }

    public static func focusAgent(_ target: String, on host: HerdrHost = .local) async throws {
        _ = try await request("agent.focus", params: ["target": target], on: host)
    }

    /// Moves the *rendered* view to a pane.
    ///
    /// `agent.focus` is not enough on its own: it updates the server's focus
    /// state and emits `workspace.focused` / `tab.focused`, and the server logs
    /// every call as ok - but the attached client does not redraw, so the
    /// screen stays where it was (seen on Herdr 0.9.0). `pane.focus` moves the
    /// view. Prefer it wherever a pane id is known.
    public static func focusPane(_ paneID: String, on host: HerdrHost = .local) async throws {
        _ = try await request("pane.focus", params: ["pane_id": paneID], on: host)
    }

    public static func listTabs(workspaceID: String? = nil, on host: HerdrHost = .local) async throws -> [HerdrTab] {
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let result = try await request("tab.list", params: params, on: host)
        let raw = result["tabs"] as? [[String: Any]] ?? []
        return raw.map(HerdrTab.init(json:))
    }

    public static func focusTab(_ tabID: String, on host: HerdrHost = .local) async throws {
        _ = try await request("tab.focus", params: ["tab_id": tabID], on: host)
    }

    /// Injects key chords into a pane, crossterm-style names ("ctrl+alt+v",
    /// "f13", "enter"). The pane's terminal encodes them as if typed.
    public static func sendKeys(paneID: String, keys: [String], on host: HerdrHost = .local) async throws {
        _ = try await request("pane.send_keys", params: ["pane_id": paneID, "keys": keys], on: host)
    }

    /// Types a string into a pane — bracketed-pasted when the pane supports
    /// it, so multi-word text lands as one block and nothing auto-submits.
    public static func sendText(paneID: String, text: String, on host: HerdrHost = .local) async throws {
        _ = try await request("pane.send_text", params: ["pane_id": paneID, "text": text], on: host)
    }

    /// Focuses the tab after the focused one in its workspace, wrapping at the
    /// end. Tabs in other workspaces are left alone: cycling is a
    /// within-window gesture, not a window switcher.
    public static func cycleTabs(on host: HerdrHost = HerdrHosts.shared.active) async throws {
        guard let next = nextTab(in: try await listTabs(on: host)) else { return }
        try await focusTab(next.tabID, on: host)
        // `tab.focus` moves the server's focus without redrawing the client,
        // exactly as `agent.focus` does - see `focusPane`. Landing on a pane
        // of the new tab is what puts it on screen. Best effort: a tab with no
        // pane is still focused, just not shown.
        if let pane = try? await firstPane(inTab: next.tabID, on: host) {
            try? await focusPane(pane, on: host)
        }
    }

    /// Any pane belonging to a tab, for turning a tab focus into a visible one.
    static func firstPane(inTab tabID: String, on host: HerdrHost = .local) async throws -> String? {
        let result = try await request("pane.list", on: host)
        let panes = result["panes"] as? [[String: Any]] ?? []
        return panes.first { $0["tab_id"] as? String == tabID }?["pane_id"] as? String
    }

    /// The tab `cycleTabs` would focus, or nil when there is nothing to do —
    /// no focused tab, or a workspace with a single tab.
    public static func nextTab(in tabs: [HerdrTab]) -> HerdrTab? {
        guard let focused = tabs.first(where: \.focused) else { return nil }
        let siblings = tabs
            .filter { $0.workspaceID == focused.workspaceID }
            .sorted { $0.number < $1.number }
        guard siblings.count > 1,
              let index = siblings.firstIndex(of: focused)
        else { return nil }
        return siblings[(index + 1) % siblings.count]
    }

    private static let counter = Counter()
    private static func nextID() -> String { "wl_\(counter.next())" }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

// MARK: - Event streams

/// One subscription, on its own connection. The first line is the
/// acknowledgement; everything after it is a pushed event.
public final class HerdrEventStream {
    public var onReady: (() -> Void)?
    public var onEvent: (([String: Any]) -> Void)?
    public var onClosed: ((Error?) -> Void)?

    private let subscriptions: [[String: Any]]
    private let conn: SocketConnection
    private var ready = false
    private var stopped = false

    public init(subscriptions: [[String: Any]], on host: HerdrHost = .local) {
        self.subscriptions = subscriptions
        self.conn = SocketConnection(path: host.socketPath)
    }

    @discardableResult
    public func start() -> HerdrEventStream {
        conn.onLine = { [weak self] line in
            guard let self, !self.stopped else { return }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if !self.ready {
                self.ready = true
                DispatchQueue.main.async { self.onReady?() }
                return
            }
            DispatchQueue.main.async { self.onEvent?(object) }
        }
        conn.onClosed = { [weak self] error in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { self.onClosed?(error) }
        }

        do {
            try conn.open()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onClosed?(error) }
            return self
        }

        let envelope: [String: Any] = [
            "id": "wl_sub",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            conn.write(payload + Data("\n".utf8))
        }
        return self
    }

    public func stop() {
        stopped = true
        conn.close()
    }

    deinit { conn.close() }
}

// MARK: - Socket plumbing

/// A blocking read loop on its own queue. Deliberately plain POSIX: the
/// alternative is Network.framework, which adds ceremony for no benefit on a
/// local Unix socket.
final class SocketConnection: @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "cc.worklouder.herdr-socket")
    private var buffer = Data()
    private var closed = false
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func open() throws {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw HerdrError.cannotConnect(path, String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, reason)
        }

        fd = handle
        queue.async { [weak self] in self?.readLoop() }
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func close() {
        lock.lock()
        let handle = fd
        fd = -1
        closed = true
        lock.unlock()
        if handle >= 0 { Darwin.close(handle) }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock(); let handle = fd; lock.unlock()
            guard handle >= 0 else { break }

            let n = Darwin.read(handle, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.prefix(upTo: index)
                buffer = buffer.suffix(from: buffer.index(after: index))
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    onLine?(line)
                }
            }
        }
        lock.lock(); let wasClosed = closed; lock.unlock()
        if !wasClosed { onClosed?(nil) }
    }
}
