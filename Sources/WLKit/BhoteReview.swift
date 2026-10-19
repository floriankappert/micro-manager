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
        /// The agent stopped while a test suite runs: its topic is testing.
        public var testing: Set<String> = []
        /// The topic is still `now`. An agent that has stopped under such a
        /// topic is finished, which is how bhote's panel lists it too.
        public var now: Set<String> = []
        /// The topic waits for a deployment of its project.
        public var deploying: Set<String> = []
        public var isEmpty: Bool {
            review.isEmpty && finished.isEmpty && testing.isEmpty && now.isEmpty && deploying.isEmpty
        }
        public init(review: Set<String> = [], finished: Set<String> = [], testing: Set<String> = [],
                    now: Set<String> = [], deploying: Set<String> = []) {
            self.deploying = deploying
            self.review = review
            self.finished = finished
            self.testing = testing
            self.now = now
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
            let deploy = status == "waiting" && topic["waiting_for"] as? String == "Deployment"
            guard status == "review" || status == "finished" || status == "testing" || status == "now" || deploy,
                  let agent = topic["agent"] as? [String: Any],
                  let pane = agent["pane"] as? String, !pane.isEmpty
            else { continue }
            let label = (agent["machine"] as? String ?? "").lowercased()
            let host = remoteNames.first { $0.lowercased() == label } ?? ""
            let key = "\(host)|\(pane)"
            if deploy { panes.deploying.insert(key); continue }
            switch status {
            case "review": panes.review.insert(key)
            case "testing": panes.testing.insert(key)
            case "now": panes.now.insert(key)
            default: panes.finished.insert(key)
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
    /// with a finished topic `finished`. An agent whose tests run is `testing`
    /// whether Herdr calls it `idle`, `done` or `working`; one whose topic waits for a
    /// deployment is `deploying`. A working or blocked agent
    /// keeps its status: it is not waiting any more.
    public static func resolve(_ agents: [HerdrAgent], panes: Panes) -> [HerdrAgent] {
        guard !panes.isEmpty else { return agents }
        return agents.map { agent in
            guard let key = agent.paneKey else { return agent }
            var copy = agent
            // Tests running under a topic are what the panel shows, even
            // while Herdr still calls the agent `working`. Only a blocked
            // agent keeps its status: it needs you whatever else runs.
            if panes.testing.contains(key), agent.status != "blocked" {
                copy.status = "testing"
                return copy
            }
            guard agent.status == "idle" || agent.status == "done" else { return agent }
            // `done` is already lit green; only a deployment changes it.
            let idle = agent.status == "idle"
            if idle && panes.review.contains(key) {
                copy.status = "review"
            } else if panes.deploying.contains(key) {
                copy.status = "deploying"
            } else if idle && (panes.finished.contains(key) || panes.now.contains(key)) {
                copy.status = "finished"
            } else {
                return agent
            }
            return copy
        }
    }
}
