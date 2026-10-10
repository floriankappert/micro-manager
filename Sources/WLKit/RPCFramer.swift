import Foundation

/// Reassembles JSON-RPC messages from the pad's fragments.
///
/// The framing carries no message boundaries, so a message is complete when
/// its top-level braces balance. That makes a single lost fragment expensive:
/// lose the report that carries a closing brace and the count never returns to
/// zero, so every later reply *and every key press* is swallowed into the
/// broken object until the buffer overflows, kilobytes later. To the person at
/// the pad that is a dead pad that comes back on its own a minute on - and over
/// Bluetooth LE reports do get lost.
///
/// So the framer resyncs on silence. The fragments of one message arrive back
/// to back; a partial object that has waited longer than `staleAfter` for its
/// next fragment will never be completed, and is dropped before the new
/// fragment is taken in.
///
/// Works on bytes rather than strings: braces and quotes are ASCII, and no
/// byte of a multi-byte UTF-8 sequence can be mistaken for one, while decoding
/// each fragment on its own fails for a character split across two of them.
struct RPCFramer {
    var staleAfter: TimeInterval = 0.5
    var capacity = 8192
    /// How many partial messages were thrown away, for diagnostics.
    private(set) var resyncs = 0
    private(set) var buffer: [UInt8] = []
    private var lastFragment: TimeInterval?

    /// Takes in one fragment and returns every message it completed.
    mutating func feed(_ fragment: [UInt8], at time: TimeInterval) -> [Data] {
        if !buffer.isEmpty, let last = lastFragment, time - last > staleAfter {
            buffer.removeAll()
            resyncs += 1
        }
        lastFragment = time
        buffer += fragment

        var messages: [Data] = []
        while let message = nextObject() { messages.append(message) }
        // Nothing before an opening brace can belong to a message, so keep the
        // buffer empty unless a message is actually in flight.
        if let start = buffer.firstIndex(of: UInt8(ascii: "{")) {
            buffer.removeSubrange(..<start)
        } else {
            buffer.removeAll()
        }
        if buffer.count > capacity {
            buffer.removeAll()
            resyncs += 1
        }
        return messages
    }

    private mutating func nextObject() -> Data? {
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false

        for (index, byte) in buffer.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == UInt8(ascii: "}"), depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    let object = Data(buffer[s...index])
                    buffer.removeSubrange(...index)
                    return object
                }
            }
        }
        return nil
    }
}
