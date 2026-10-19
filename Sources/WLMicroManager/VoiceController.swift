import AppKit
import WLKit

/// The wide bottom key: taps **right command**, which is Superwhisper's
/// start/stop.
///
/// Superwhisper is system-wide and types into whatever holds focus, so this
/// deliberately does not care which agent Herdr has focused, or whether Herdr
/// is running at all. That is the difference from what this key used to do: it
/// asked Herdr for the focused agent and forked — Claude Code got a chord
/// injected into its pane for its own voice mode, everything else got macOS
/// dictation. One transcriber for every harness is simpler, and it is the one
/// press that has to work when you are mid-thought.
///
/// Posting a key event needs the **Accessibility** grant, on top of the Input
/// Monitoring grant the pad needs. `KeystrokeController` asks for it and words
/// the refusal.
@MainActor
final class VoiceController {

    static let shared = VoiceController()

    /// Right command. Its left twin is a different key code, and Superwhisper
    /// distinguishes them, so this must be the right-hand one.
    static let triggerKey: CGKeyCode = 0x36

    /// Superwhisper's state, for the key light. It has no API, so `start()`
    /// watches its recordings folder instead of trusting
    /// how often the key was pressed.
    var onStateChange: ((VoiceState) -> Void)?
    var onError: ((String) -> Void)?

    private var state = VoiceState.waiting
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let next = Superwhisper.state(newest: Superwhisper.newestTake())
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }

    func handleVoiceKey() {
        do {
            try tapTriggerKey()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// The tap itself, the Accessibility check and the error wording all live
    /// in `KeystrokeController` — it posts every other synthetic key this app
    /// sends, and a modifier is only a key with its flag set.
    private func tapTriggerKey() throws {
        try KeystrokeController.shared.tap(Self.triggerKey, flags: .maskCommand)
    }
}
