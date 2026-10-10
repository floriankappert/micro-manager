import Foundation
import IOKit
import IOKit.hid
import os

/// Raw-HID JSON-RPC transport for Work Louder devices.
///
/// Framing, on 64-byte reports carried by the vendor collection
/// (usage page 0xFF00 / usage 1):
///
///     byte 0      report id, always 0x06
///     byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
///     byte 2      payload length in this report, max 61
///     bytes 3..   UTF-8 fragment of the JSON message
///
/// Messages are split across as many reports as needed and reassembled by
/// scanning for balanced top-level braces.
///
/// The device must be opened **non-exclusively**. Its vendor collection shares
/// an IOHIDDevice with a keyboard collection, and macOS refuses to let anything
/// seize a keyboard — a seizing open fails with 0xE00002C1, which looks exactly
/// like a missing Input Monitoring grant and is not.
public final class WLDevice {

    public static let vendorID = 0x303A
    public static let reportID: UInt8 = 0x06
    public static let channelDebug: UInt8 = 1
    public static let channelRPC: UInt8 = 2
    public static let maxChunk = 61
    public static let reportSize = 64

    public struct Info {
        public var product: String
        public var productID: Int
        public var transport: String
        public var serial: String
        public var usagePage: Int
        public var interfaceCount: Int
    }

    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 0x01

    public enum Failure: LocalizedError {
        case notFound
        case noVendorCollection
        case openFailed(IOReturn, String)
        case notConnected
        case writeFailed(IOReturn)
        case timeout(String)
        case rpc(String, String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Work Louder device on the HID bus. If it is a Bluetooth pad it may have gone to sleep — press a key to wake it."
            case .noVendorCollection:
                return "Found the device, but not its vendor collection (usage page 0xFF00). Nothing to talk to."
            case .openFailed(let r, let detail):
                // Two codes mean "no Input Monitoring grant": NotPrivileged
                // (0xE00002C1) on older systems, NotPermitted (0xE00002E2) on
                // macOS 26. Both read like bugs unless named.
                let code = UInt32(bitPattern: r)
                if r == kIOReturnNotPrivileged || r == kIOReturnNotPermitted
                    || code == 0xE00002C1 || code == 0xE00002E2 {
                    return String(format: "Open refused (0x%08X). ", code)
                        + "Grant Input Monitoring to the process running this app, under System Settings → Privacy & Security → Input Monitoring. [\(detail)]"
                }
                return String(format: "IOHIDDeviceOpen failed (0x%08X) [%@]", UInt32(bitPattern: r), detail)
            case .notConnected:
                return "Not connected."
            case .writeFailed(let r):
                let code = UInt32(bitPattern: r)
                let name: String
                switch code {
                case 0xE00002CD: name = " — kIOReturnNotOpen, the device handle is no longer open"
                case 0xE00002C0: name = " — kIOReturnNoDevice"
                case 0xE00002C5: name = " — kIOReturnExclusiveAccess"
                case 0xE00002C1: name = " — kIOReturnNotPrivileged"
                case 0xE00002C7: name = " — kIOReturnUnsupported, wrong report id or interface"
                default: name = ""
                }
                return String(format: "IOHIDDeviceSetReport failed (0x%08X)", code) + name
            case .timeout(let m):
                return "Timed out waiting for \(m)."
            case .rpc(let method, let message):
                return "\(method): \(message)"
            }
        }
    }

    // Callbacks, always delivered on the main queue.
    public var onTX: ((String, Any?, Int) -> Void)?          // method, params, id
    public var onResponse: ((Int, Any?, String?) -> Void)?   // id, result, errorMessage
    public var onNotification: ((String, Any?) -> Void)?     // method, params
    public var onDeviceLog: ((String) -> Void)?
    public var onWriteError: ((String, String) -> Void)?
    /// Every input report, before framing. Reports that do not match the
    /// channel framing are otherwise dropped, which hides any other traffic
    /// the device emits - key presses included.
    public var onRawReport: ((UInt32, [UInt8]) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    public private(set) var info: Info?
    /// When set, every call is answered by this instead of by the HID bus, and
    /// nothing touches IOKit. See `PadEmulator`.
    public let emulator: PadEmulator?
    private var emulatedConnected = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
    private var framer = RPCFramer()
    private var debugAccumulator = ""
    /// Calls that timed out since the pad last sent anything at all. A pad
    /// that stays silent through several is gone, whatever IOKit says: over
    /// Bluetooth the handle can outlive the link without a removal callback,
    /// and the bridge would otherwise sit "connected" to nothing.
    private var silentTimeouts = 0
    public static let maxSilentTimeouts = 3
    static let log = Logger(subsystem: "cc.worklouder.wlkit", category: "device")
    private var pending: [Int: (Any?, String?) -> Void] = [:]
    private var nextID = 1

    public var isConnected: Bool { device != nil || emulatedConnected }

    public init(emulator: PadEmulator? = nil) { self.emulator = emulator }

    deinit { inputBuffer.deallocate() }

    // MARK: - Connect

    public func connect() throws {
        disconnect(reason: nil)

        if let emulator {
            emulatedConnected = true
            info = Info(
                product: "Creator Micro 2 (emulated)",
                productID: 0x8297,
                transport: "emulated",
                serial: "EMULATOR",
                usagePage: WLDevice.vendorUsagePage,
                interfaceCount: 1
            )
            emulator.onNotify = { [weak self] method, params in
                guard let self else { return }
                DispatchQueue.main.async { self.onNotification?(method, params) }
            }
            return
        }

        // Must be held for the lifetime of the connection: releasing the
        // manager tears down the devices it opened, and every later SetReport
        // then fails with kIOReturnNotOpen.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // Match on vendor only: over Bluetooth the pad presents a single
        // IOHIDDevice whose *primary* usage is keyboard, with the vendor
        // collection alongside it in DeviceUsagePairs.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WLDevice.vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            throw Failure.notFound
        }
        // Over Bluetooth the pad is a single IOHIDDevice whose primary usage is
        // keyboard, with the vendor collection alongside it in DeviceUsagePairs.
        // Over USB each interface is its own IOHIDDevice, so picking the first
        // match lands on the keyboard and every report id 6 write is dropped.
        // Select the one that actually carries the vendor collection.
        guard let dev = set.first(where: { primaryUsagePage($0) == WLDevice.vendorUsagePage })
            ?? set.first(where: { hasVendorCollection($0) })
        else {
            throw Failure.noVendorCollection
        }

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // Say what was being opened and what TCC thinks, so a refusal can
            // be told apart from a permission that is simply missing.
            let access: String
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: access = "granted"
            case kIOHIDAccessTypeDenied: access = "denied"
            default: access = "not asked"
            }
            let matched = set.map { d -> String in
                let page = primaryUsagePage(d).map { String(format: "0x%04X", $0) } ?? "?"
                return "\(string(d, kIOHIDTransportKey) ?? "?")/\(page)"
            }.joined(separator: ", ")
            let chosen = String(format: "0x%04X", primaryUsagePage(dev) ?? 0)
            throw Failure.openFailed(result,
                "Input Monitoring \(access); opened \(string(dev, kIOHIDTransportKey) ?? "?") device with primary usage page \(chosen); matched: \(matched)")
        }

        device = dev
        info = Info(
            product: string(dev, kIOHIDProductKey) ?? "Work Louder device",
            productID: number(dev, kIOHIDProductIDKey) ?? 0,
            transport: string(dev, kIOHIDTransportKey) ?? "?",
            serial: string(dev, kIOHIDSerialNumberKey) ?? "",
            usagePage: primaryUsagePage(dev) ?? 0,
            interfaceCount: set.count
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, WLDevice.reportSize, { ctx, _, _, _, reportID, report, length in
            guard let ctx, length > 0 else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            DispatchQueue.main.async { me.handleReport(bytes, reportID: reportID) }
        }, context)

        IOHIDDeviceRegisterRemovalCallback(dev, { ctx, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.disconnect(reason: "device removed") }
        }, context)

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        WLDevice.log.notice("connected: \(self.info?.product ?? "?", privacy: .public) over \(self.info?.transport ?? "?", privacy: .public)")
    }

    public func disconnect(reason: String?) {
        if emulator != nil {
            guard emulatedConnected else { return }
            emulatedConnected = false
            emulator?.onNotify = nil
            info = nil
            for (_, done) in pending { done(nil, "disconnected") }
            pending.removeAll()
            if let reason { onDisconnect?(reason) }
            return
        }
        guard let dev = device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        info = nil
        if framer.resyncs > 0 {
            WLDevice.log.notice("framer dropped \(self.framer.resyncs) partial message(s) this session")
        }
        framer = RPCFramer()
        debugAccumulator = ""
        silentTimeouts = 0
        for (_, done) in pending { done(nil, "disconnected") }
        pending.removeAll()
        WLDevice.log.notice("disconnected: \(reason ?? "on request", privacy: .public)")
        if let reason { onDisconnect?(reason) }
    }

    // MARK: - Send

    @discardableResult
    public func call(_ method: String, params: Any?, completion: ((Any?, String?) -> Void)? = nil) -> Int? {
        guard emulatedConnected || device != nil else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        // Firmware only accepts call ids below 1000.
        let id = nextID
        nextID = nextID % 998 + 1

        if let emulator {
            onTX?(method, params, id)
            // Answer on the next turn of the run loop rather than inline: a
            // real call is never synchronous, and callers that assume it is
            // would work here and deadlock on hardware.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let (result, error) = emulator.handle(method, params: params)
                self.onResponse?(id, result, error)
                completion?(result, error)
            }
            return id
        }

        guard let dev = device else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        var message: [String: Any] = ["method": method, "id": id]
        message["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            completion?(nil, "could not encode params")
            return nil
        }

        let payload = [UInt8](data)
        var offset = 0
        while offset < payload.count {
            let n = min(WLDevice.maxChunk, payload.count - offset)
            var report = [UInt8](repeating: 0, count: WLDevice.reportSize)
            report[0] = WLDevice.reportID
            report[1] = WLDevice.channelRPC
            report[2] = UInt8(n)
            report.replaceSubrange(3..<(3 + n), with: payload[offset..<(offset + n)])

            let rc = report.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(WLDevice.reportID), buf.baseAddress!, buf.count)
            }
            guard rc == kIOReturnSuccess else {
                // Surface the failure rather than dropping it: a silent write
                // error is indistinguishable from a device that ignores you.
                let message = Failure.writeFailed(rc).errorDescription ?? "write failed"
                WLDevice.log.error("write failed for \(method, privacy: .public): \(message, privacy: .public)")
                onWriteError?(method, message)
                completion?(nil, message)
                // These mean the handle is dead. Left alone, every later call
                // fails the same way while the bridge still reads connected,
                // so drop it and let the owner reopen. Deferred, so nothing is
                // torn down under the caller still unwinding from this call.
                if WLDevice.deadHandleCodes.contains(UInt32(bitPattern: rc)) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.device === dev else { return }
                        self.disconnect(reason: message)
                    }
                }
                return nil
            }
            offset += n
        }

        onTX?(method, params, id)

        if let completion {
            pending[id] = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting(nil, Failure.timeout(method).errorDescription)
                self.noteTimeout(method, handle: dev)
            }
        }
        return id
    }

    /// kIOReturnNotOpen, kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnAborted.
    static let deadHandleCodes: Set<UInt32> = [0xE00002CD, 0xE00002C0, 0xE00002D9, 0xE00002EB]

    private func noteTimeout(_ method: String, handle: IOHIDDevice) {
        // A timeout that lands after a reconnect belongs to the old handle.
        guard device === handle else { return }
        silentTimeouts += 1
        WLDevice.log.notice("\(method, privacy: .public) timed out (\(self.silentTimeouts) in a row with no traffic)")
        guard silentTimeouts >= WLDevice.maxSilentTimeouts else { return }
        disconnect(reason: "the pad stopped answering (\(silentTimeouts) calls timed out)")
    }

    // MARK: - Receive

    private func handleReport(_ bytes: [UInt8], reportID: UInt32) {
        // Any report at all - a key, a log line, a reply - proves the link.
        silentTimeouts = 0
        onRawReport?(reportID, bytes)
        // The input callback delivers the report id out-of-band, so the
        // payload normally starts at index 0 — but be tolerant of stacks that
        // include it, and try the shifted alignment too.
        if !parse(bytes, at: 0) { _ = parse(bytes, at: 1) }
    }

    private func parse(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard bytes.count > offset + 2 else { return false }
        let channel = bytes[offset]
        let length = Int(bytes[offset + 1])
        guard channel == WLDevice.channelRPC || channel == WLDevice.channelDebug else { return false }
        guard length > 0, length <= WLDevice.maxChunk, bytes.count >= offset + 2 + length else { return false }

        let slice = Array(bytes[(offset + 2)..<(offset + 2 + length)])

        if channel == WLDevice.channelDebug {
            guard let text = String(bytes: slice, encoding: .utf8) else { return false }
            debugAccumulator += text
            while let idx = debugAccumulator.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(debugAccumulator[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                debugAccumulator = String(debugAccumulator[debugAccumulator.index(after: idx)...])
                if !line.isEmpty { onDeviceLog?(line) }
            }
            if debugAccumulator.count > 4096 { debugAccumulator = "" }
            return true
        }

        let resyncs = framer.resyncs
        let messages = framer.feed(slice, at: ProcessInfo.processInfo.systemUptime)
        if framer.resyncs > resyncs {
            WLDevice.log.notice("dropped a partial message: a fragment went missing")
        }
        messages.forEach(dispatch)
        return true
    }

    private func dispatch(_ message: Data) {
        guard let decoded = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        else { return }

        if let id = decoded["id"] as? Int {
            let error = (decoded["error"] as? [String: Any])?["message"] as? String
            let result = decoded["result"]
            onResponse?(id, result, error)
            if let waiting = pending.removeValue(forKey: id) { waiting(result, error) }
        } else if let method = (decoded["m"] as? String) ?? (decoded["method"] as? String) {
            // Device-pushed notification. Note the envelope is abbreviated
            // here - {"m": method, "p": params} - while responses use the
            // full "method". Matching only on "method" drops every one.
            let params = decoded["m"] != nil ? decoded["p"] : decoded["params"]
            onNotification?(method, params)
        }
    }

    // MARK: - Properties

    private func string(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }

    private func number(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }

    private func primaryUsagePage(_ dev: IOHIDDevice) -> Int? {
        number(dev, kIOHIDPrimaryUsagePageKey)
    }

    /// True when this IOHIDDevice exposes the vendor collection, either as its
    /// primary usage or as one of its DeviceUsagePairs.
    private func hasVendorCollection(_ dev: IOHIDDevice) -> Bool {
        if primaryUsagePage(dev) == WLDevice.vendorUsagePage { return true }
        guard let pairs = IOHIDDeviceGetProperty(dev, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
        else { return false }
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == WLDevice.vendorUsagePage }
    }
}
