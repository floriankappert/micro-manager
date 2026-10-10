import AppKit

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

    /// Mirrors an open take, for the key light.
    var onActiveChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Which half of the start/stop cycle we are in. Only the light cares —
    /// stopping a take from the keyboard makes this drift, and the next press
    /// resynchronises it.
    private var takeOpen = false

    func handleVoiceKey() {
        do {
            try tapTriggerKey()
            takeOpen.toggle()
            onActiveChange?(takeOpen)
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
