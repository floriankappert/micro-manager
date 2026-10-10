import AppKit
import WLKit

/// Posts the plain keystrokes and system commands a key — or the dial — can be
/// bound to.
///
/// These go out as real events on the HID tap, not into a Herdr pane: enter and
/// delete are only useful where the cursor already is, and the volume keys are
/// the machine's, not any agent's. That also means they work with Herdr closed,
/// which is the point of having them on a pad at all.
///
/// Posting needs the **Accessibility** grant, on top of the Input Monitoring
/// grant the pad needs. `ensureTrusted` raises the system prompt the first time.
@MainActor
final class KeystrokeController {

    static let shared = KeystrokeController()

    var onError: ((String) -> Void)?

    /// Virtual key codes, from `Events.h`.
    private enum Key {
        static let enter: CGKeyCode = 0x24
        static let backspace: CGKeyCode = 0x33
        static let forwardDelete: CGKeyCode = 0x75
        static let escape: CGKeyCode = 0x35
    }

    /// `NX_KEYTYPE_SOUND_UP` and `NX_KEYTYPE_SOUND_DOWN`. The volume keys are
    /// not virtual key codes: they ride a system-defined event, which is what
    /// gives the on-screen volume HUD and respects the current output device.
    private enum MediaKey {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
    }

    /// `kVK_ANSI_1` ... `kVK_ANSI_9`, which are not in key order.
    private static let digits: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    /// Alt plus a digit, 1...9: Herdr's `focus_agent` row binding, set up as
    /// `[keys.indexed] agents = "alt"`. Ghostty has to send option as alt.
    func focusAgentRow(_ row: Int) {
        guard (1...9).contains(row) else { return }
        do {
            try tap(Self.digits[row - 1], flags: .maskAlternate)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func handle(_ action: KeyBindings.Action) {
        do {
            switch action {
            case .enter: try tap(Key.enter)
            case .delete: try tap(Key.forwardDelete)
            case .backspace: try tap(Key.backspace)
            case .escape: try tap(Key.escape)
            case .volumeUp: try tapMedia(MediaKey.soundUp)
            case .volumeDown: try tapMedia(MediaKey.soundDown)
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Presses and releases a key. `flags` carries a modifier's own flag, which
    /// a modifier key needs and a plain key must leave empty.
    func tap(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try ensureTrusted()
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw Failure.eventFailed }
        down.flags = flags
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// One press of a media key: a `.systemDefined` event of subtype 8, whose
    /// `data1` packs the key and whether it is going down or up.
    private func tapMedia(_ key: Int32) throws {
        try ensureTrusted()
        for down in [true, false] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | (down ? 0xA00 : 0xB00)),
                data2: -1
            )?.cgEvent else { throw Failure.eventFailed }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Raises the Accessibility prompt the first time, and reports the refusal
    /// by name rather than as a silent no-op.
    func ensureTrusted() throws {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            throw Failure.accessibilityDenied
        }
    }

    enum Failure: LocalizedError {
        case accessibilityDenied
        case eventFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Sending a keystroke needs the Accessibility permission: "
                    + "System Settings → Privacy & Security → Accessibility → Micro Manager."
            case .eventFailed:
                return "Could not synthesise the key press."
            }
        }
    }
}
