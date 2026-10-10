import Foundation
import os

/// A Herdr server on another machine, from the config file:
///
///     "remotes": [{"name": "omarchy", "ssh": "omarchy-flo"}]
///
/// `ssh` is anything `ssh` itself accepts as a destination, so a `~/.ssh/config`
/// alias works. `socket` is the server's socket path on that machine; left out,
/// it is asked for once over SSH, the same way Herdr resolves it. A bare
/// string, `"remotes": ["omarchy-flo"]`, uses the destination as the name too.
public struct HerdrRemote: Equatable, Sendable {
    public var name: String
    public var ssh: String
    public var socket: String?

    public init(name: String, ssh: String, socket: String? = nil) {
        self.name = name
        self.ssh = ssh
        self.socket = socket
    }

    public static func load() -> [HerdrRemote] {
        guard let data = FileManager.default.contents(atPath: KeyBindings.configPath()) else { return [] }
        return parse(data)
    }

    /// Entries without a destination are skipped, and a name used twice keeps
    /// its first entry: the name keys the tunnel's socket.
    static func parse(_ data: Data) -> [HerdrRemote] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["remotes"] as? [Any]
        else { return [] }
        var seen = Set<String>()
        return list.compactMap { item -> HerdrRemote? in
            let remote: HerdrRemote
            if let destination = item as? String {
                remote = HerdrRemote(name: destination, ssh: destination)
            } else if let entry = item as? [String: Any], let destination = entry["ssh"] as? String {
                let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? destination
                let socket = (entry["socket"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                remote = HerdrRemote(name: name, ssh: destination, socket: socket)
            } else {
                return nil
            }
            guard !remote.ssh.isEmpty, !remote.name.contains("/"), seen.insert(remote.name).inserted
            else { return nil }
            return remote
        }
    }
}

/// Forwards a remote Herdr socket to a local one with `ssh -L`, and keeps it
/// forwarded.
///
/// A forwarded Unix socket is indistinguishable from a local server, so
/// everything above this - requests, event streams, focus - works unchanged
/// against the remote; it only needs the other path. SSH exits when the link
/// dies (the keepalives make sure it notices), and the tunnel comes back up
/// with a backoff, so a machine that sleeps rejoins when it wakes.
///
/// No authentication is set up here: `BatchMode` makes SSH fail rather than
/// prompt, so a destination has to be reachable without a password - a key in
/// the agent, or Tailscale SSH.
@MainActor
public final class HerdrTunnel {
    public let remote: HerdrRemote
    public let host: HerdrHost
    /// Why the tunnel is down, or nil while SSH runs.
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?

    private var process: Process?
    private var loop: Task<Void, Never>?
    private var remoteSocket: String?
    private static let log = Logger(subsystem: "cc.worklouder.wlkit", category: "tunnel")

    public init(remote: HerdrRemote) {
        self.remote = remote
        self.remoteSocket = remote.socket
        self.host = HerdrHost(name: remote.name, socketPath: HerdrTunnel.directory + "/\(remote.name).sock")
    }

    public static var directory: String {
        ((KeyBindings.configPath() as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("tunnels")
    }

    private var pidPath: String { HerdrTunnel.directory + "/\(remote.name).pid" }

    public func start() {
        guard loop == nil else { return }
        try? FileManager.default.createDirectory(
            atPath: HerdrTunnel.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        killOrphan()
        loop = Task { [weak self] in
            var delay: TimeInterval = 2
            while !Task.isCancelled {
                guard let self else { return }
                let began = Date()
                await self.runOnce()
                if Task.isCancelled { break }
                // A session that held for a while earns a quick retry; one
                // that dies at once is refused or unreachable, so back off.
                delay = Date().timeIntervalSince(began) > 60 ? 2 : min(delay * 2, 30)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        process?.terminate(); process = nil
        try? FileManager.default.removeItem(atPath: pidPath)
        try? FileManager.default.removeItem(atPath: host.socketPath)
    }

    private static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        // Notice a dead link within half a minute instead of never.
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=3",
        // A multiplexed master would outlive this process and hold the
        // forward in a place `terminate` does not reach.
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
    ]

    private func runOnce() async {
        if remoteSocket == nil {
            // Resolved the way Herdr does it, in `sh` so the remote login shell
            // does not matter.
            let script = #"sh -c 'printf %s "${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"'"#
            let result = await Self.run(Self.sshOptions + [remote.ssh, script])
            guard result.status == 0, result.output.hasPrefix("/") else {
                fail(result.error.isEmpty ? "ssh \(remote.ssh) exited \(result.status)" : result.error)
                return
            }
            remoteSocket = result.output
        }
        guard let remoteSocket, !Task.isCancelled else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-N", "-T"] + Self.sshOptions + [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "\(host.socketPath):\(remoteSocket)",
            remote.ssh,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
                return
            }
            self.process = process
            try? "\(process.processIdentifier)".write(toFile: pidPath, atomically: true, encoding: .utf8)
            lastError = nil
            onChange?()
            Self.log.notice("tunnel to \(self.remote.ssh, privacy: .public) up")
        }
        self.process = nil
        guard !Task.isCancelled else { return }
        let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        fail(detail.isEmpty ? "ssh \(remote.ssh) exited \(status)" : detail)
    }

    private func fail(_ message: String) {
        lastError = message
        Self.log.notice("tunnel to \(self.remote.ssh, privacy: .public) down: \(message, privacy: .public)")
        onChange?()
    }

    /// An SSH left behind by a run of the app that crashed would still hold
    /// the socket. Only an `ssh` is killed, so a recycled pid is left alone.
    private func killOrphan() {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           String(cString: path) == "/usr/bin/ssh" {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    private static func run(_ arguments: [String]) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (
                    finished.terminationStatus,
                    output.trimmingCharacters(in: .whitespacesAndNewlines),
                    error.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                ))
            }
            do { try process.run() } catch {
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
}
