import Foundation

/// What the dictation key shows: nothing is happening, Superwhisper is
/// listening, or it has stopped listening and is still transcribing.
public enum VoiceState: Equatable, Sendable {
    case waiting, listening, processing
}

/// Reads Superwhisper's state from the outside: it has no API, so this reads
/// what it leaves behind in `~/superwhisper/recordings/<n>/` for the newest
/// take.
///
/// While a take is open `output.wav` keeps growing: that is `listening`.
/// `meta.json` gets its `result` only once transcription is done, so a take
/// without one whose audio has stopped growing is `processing`.
///
/// The microphone itself is no signal on a Mac where Teams or Zoom hold the
/// input device open all day, so `micRunning` is only a tie-breaker for the
public enum Superwhisper {

    public struct Take: Equatable, Sendable {
        /// When `output.wav` was last written.
        public var audioModified: Date?
        /// `meta.json` holds the transcription already.
        public var hasResult: Bool
        public init(audioModified: Date?, hasResult: Bool) {
            self.audioModified = audioModified
            self.hasResult = hasResult
        }
    }

    /// `growingWithin`: how recently the audio must have been written to still
    /// count as growing. `giveUpAfter`: a take that never gets a result
    /// (cancelled) must not read as processing for ever.
    public static func state(
        newest: Take?,
        now: Date = Date(),
        growingWithin: TimeInterval = 2,
        giveUpAfter: TimeInterval = 60
    ) -> VoiceState {
        guard let newest, !newest.hasResult, let modified = newest.audioModified else { return .waiting }
        let age = now.timeIntervalSince(modified)
        if age < growingWithin { return .listening }
        return age < giveUpAfter ? .processing : .waiting
    }

    public static var recordingsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("superwhisper/recordings")
    }

    /// The take with the highest number (a Unix time) in the directory.
    public static func newestTake(in directory: URL = recordingsDirectory) -> Take? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path),
              let newest = names.compactMap({ name in Int(name).map { (name, $0) } }).max(by: { $0.1 < $1.1 })
        else { return nil }
        let folder = directory.appendingPathComponent(newest.0)
        let audio = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("output.wav").path)[.modificationDate] as? Date
        let meta = try? Data(contentsOf: folder.appendingPathComponent("meta.json"))
        let object = meta.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return Take(audioModified: audio ?? nil, hasResult: object?["result"] != nil)
    }
}
