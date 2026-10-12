import Foundation

/// Which agents are waiting on you, according to bhote.
///
/// Herdr only knows `done` (finished, not yet looked at) and `idle`. An agent
/// that finished by asking a question is `idle` as soon as you have glanced at
/// its pane, which is exactly when it is still waiting for an answer. bhote
/// knows better: its topic for that agent is in `review`. This reads those
/// topics so the pad can show the agent as `review` instead of `idle`.
///
/// bhote is optional. Without the binary, or when it fails, nothing is
/// reported and agents keep Herdr's own status.
public enum BhoteReview {

    /// The panes bhote has something to say about, as `HerdrAgent.paneKey`s.
    public struct Panes: Equatable, Sendable {
        /// The agent asked something: its topic is in review.
        public var review: Set<String> = []
        /// The agent stopped without a question: its topic is finished.
        public var finished: Set<String> = []
        public var isEmpty: Bool { review.isEmpty && finished.isEmpty }
        public init(review: Set<String> = [], finished: Set<String> = []) {
            self.review = review
            self.finished = finished
        }
    }

    /// bhote names a machine by label ("Mac", "Omarchy"), Herdr by the remote's
    /// configured name. A label that matches a remote, ignoring case, is that
    /// remote; any other label is taken to be this Mac.
    public static func panes(from json: Data, remoteNames: [String]) -> Panes {
        guard let topics = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]]
        else { return Panes() }
        var panes = Panes()
        for topic in topics {
            let status = topic["status"] as? String
            guard status == "review" || status == "finished",
                  let agent = topic["agent"] as? [String: Any],
                  let pane = agent["pane"] as? String, !pane.isEmpty
            else { continue }
            let label = (agent["machine"] as? String ?? "").lowercased()
            let host = remoteNames.first { $0.lowercased() == label } ?? ""
            if status == "review" {
                panes.review.insert("\(host)|\(pane)")
            } else {
                panes.finished.insert("\(host)|\(pane)")
            }
        }
        return panes
    }

    /// Where bhote usually lives. An app started from the Dock has no shell
    /// PATH, so the plain name would not be found.
    static var executable: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/bhote", "/opt/homebrew/bin/bhote", "/usr/local/bin/bhote"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `bhote list --json`; nil when bhote is missing, slow or failing.
    public static func fetch(remoteNames: [String], timeout: TimeInterval = 4) async -> Panes? {
        guard let path = executable else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["list", "--json"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard process.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: panes(from: data, remoteNames: remoteNames))
            }
        }
    }

    /// Herdr's `idle` agents that bhote has in review become `review`, those
    /// with a finished topic `finished`. A working or blocked agent keeps its
    /// status: it is not waiting any more.
    public static func resolve(_ agents: [HerdrAgent], panes: Panes) -> [HerdrAgent] {
        guard !panes.isEmpty else { return agents }
        return agents.map { agent in
            guard agent.status == "idle", let key = agent.paneKey else { return agent }
            var copy = agent
            if panes.review.contains(key) {
                copy.status = "review"
            } else if panes.finished.contains(key) {
                copy.status = "finished"
            } else {
                return agent
            }
            return copy
        }
    }
}
