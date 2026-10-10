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

    /// `paneKey`s (`HerdrAgent.paneKey`) of the agents whose topic is in review.
    ///
    /// bhote names a machine by label ("Mac", "Omarchy"), Herdr by the remote's
    /// configured name. A label that matches a remote, ignoring case, is that
    /// remote; any other label is taken to be this Mac.
    public static func reviewPanes(from json: Data, remoteNames: [String]) -> Set<String> {
        guard let topics = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]]
        else { return [] }
        var keys: Set<String> = []
        for topic in topics where topic["status"] as? String == "review" {
            guard let agent = topic["agent"] as? [String: Any],
                  let pane = agent["pane"] as? String, !pane.isEmpty
            else { continue }
            let label = (agent["machine"] as? String ?? "").lowercased()
            let host = remoteNames.first { $0.lowercased() == label } ?? ""
            keys.insert("\(host)|\(pane)")
        }
        return keys
    }

    /// Where bhote usually lives. An app started from the Dock has no shell
    /// PATH, so the plain name would not be found.
    static var executable: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/bhote", "/opt/homebrew/bin/bhote", "/usr/local/bin/bhote"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `bhote list --json`; nil when bhote is missing, slow or failing.
    public static func fetch(remoteNames: [String], timeout: TimeInterval = 4) async -> Set<String>? {
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
                continuation.resume(returning: reviewPanes(from: data, remoteNames: remoteNames))
            }
        }
    }

    /// Herdr's `idle` agents that bhote has in review become `review`. A
    /// working or blocked agent keeps its status: it is not waiting any more.
    public static func resolve(_ agents: [HerdrAgent], reviewPanes: Set<String>) -> [HerdrAgent] {
        guard !reviewPanes.isEmpty else { return agents }
        return agents.map { agent in
            guard agent.status == "idle", let key = agent.paneKey, reviewPanes.contains(key)
            else { return agent }
            var copy = agent
            copy.status = "review"
            return copy
        }
    }
}
