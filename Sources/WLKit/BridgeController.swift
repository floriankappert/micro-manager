import Foundation
import SwiftUI
import IOKit
import IOKit.hid
import os

/// Drives the pad from Herdr agent status: each agent gets its own key, and the
/// underglow carries a worst-state-wins aggregate.
///
/// Liveness comes from three places, so a missed event can never leave the pad
/// showing something stale:
///   1. a lifecycle stream (panes appearing, disappearing, gaining agents)
///   2. one status stream per agent pane (instant transitions)
///   3. a slow poll of `agent.list` as a backstop
///
/// `agent.list` is always the source of truth; events only decide *when* to
/// look. This is a port of `bin/leds.js` — including the parts that were bug
/// fixes, which are called out where they matter.
@MainActor
public final class BridgeController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    /// Which layer of the pad the keycodes are bound on, 0-based. The pad has
    /// its own layer switcher, so this is not a constant.
    @Published public private(set) var activeLayer = 0
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var deviceName = "—"
    @Published public private(set) var firmware = "—"
    @Published public private(set) var battery: String?
    @Published public private(set) var agents: [HerdrAgent] = []
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: String?
    @Published public private(set) var lastError: String?
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// One line per configured remote Herdr that is not answering, so a
    /// machine that went to sleep reads as that and not as missing agents.
    @Published public private(set) var remoteProblems: [String] = []
    /// Whether the GitButler stack is on screen. Only the key light cares —
    /// the panel itself lives in the app layer.
    @Published public private(set) var stackPanelOpen = false
    /// Same for the land window.
    @Published public private(set) var landPanelOpen = false
    /// Whether a Claude voice take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false

    public var config: BridgeConfig
    /// Text macros for the spare keys, reloaded on every bridge start so a
    /// config edit only needs an off/on toggle, not a relaunch.
    public private(set) var keyBindings = KeyBindings.load()

    /// Called when the stack key is pressed. The bridge owns the key, the app
    /// owns the window, so this is where the two meet.
    public var onStackKey: (() -> Void)?
    /// Called when the land key is pressed; same split as `onStackKey`.
    public var onLandKey: (() -> Void)?
    /// Called when either half of the wide voice key is pressed.
    public var onVoiceKey: (() -> Void)?
    /// Called per dial detent: +1 clockwise, -1 counter-clockwise. Silent
    /// while the dial is configured for something the app layer owns instead.
    public var onDial: ((Int) -> Void)?
    /// Called with the keystroke a key — or the dial, when it is set to
    /// volume — is bound to. The bridge decides *which* action; posting it is
    /// the app layer's job, because it needs the Accessibility grant.
    public var onAction: ((KeyBindings.Action) -> Void)?
    /// Presses Herdr's `focus_agent` row binding - alt plus a digit, 1...9 -
    /// in the frontmost terminal. The app layer posts it, since posting needs
    /// the Accessibility grant.
    public var onFocusAgentRow: ((Int) -> Void)?
    /// Called when the joystick enters a cardinal sector.
    public var onJoystick: ((Pad.JoystickDirection) -> Void)?
    /// Consulted before any key does its normal job. Returning true consumes
    /// the press — this is how a pending land confirmation turns every other
    /// key into "cancel" without those keys also doing their usual work.
    public var onKeyIntercept: ((Int) -> Bool)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    private var lifecycles: [HerdrHost: HerdrEventStream] = [:]
    private var tunnels: [HerdrTunnel] = []
    /// Keyed by `HerdrAgent.paneKey`: pane ids repeat across servers.
    private var statusStreams: [String: HerdrEventStream] = [:]
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var lastFingerprint: String? {
        // A full repaint rewrites every key, so forget what was last sent.
        didSet { if lastFingerprint == nil { sentThreads = [:] } }
    }
    /// What each key was last told. Only keys whose picture changed are
    /// rewritten, so a key that keeps its look is not disturbed when another
    /// agent changes state (a write may restart the key's breathing).
    private var sentThreads: [Int: OAI.Thread] = [:]
    /// Panes whose bhote topic is in review, refreshed in the background so a
    /// slow bhote never holds up a repaint.
    private var reviewPanes: Set<String> = []
    private var reviewFetchedAt = Date.distantPast
    private var reviewFetching = false
    /// When each agent was first seen working, by `HerdrAgent.paneKey`.
    private var workingSince: [String: Date] = [:]
    private var issuedIDs = Set<Int>()
    private var warnedPermission = false

    public init(config: BridgeConfig = BridgeConfig()) {
        self.config = config
        wire(device)
    }

    /// Swap the hardware for a virtual pad, or back. The device is rebuilt
    /// either way, so the bridge reconnects from scratch rather than trying to
    /// carry state across a transport it no longer has.
    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil) else { return }
        let wasRunning = isRunning
        if wasRunning { await stop() }
        let pad = on ? PadEmulator() : nil
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
        if wasRunning { await start() }
    }

    private func wire(_ device: WLDevice) {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false
            self.lastFingerprint = nil
            if self.isRunning { self.scheduleReopen() }
        }
        device.onTX = { [weak self] _, _, id in
            self?.issuedIDs.insert(id)
        }
        device.onResponse = { [weak self] id, _, _ in
            guard let self else { return }
            // A reply to an id we never sent came from another client.
            if self.issuedIDs.remove(id) == nil { self.contendingClient = true }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, method == OAI.notifyHID else { return }
            guard let dict = params as? [String: Any] else { return }
            guard (dict["act"] as? Int) == 1 else { return }   // press, not release
            guard let index = OAI.agIndex(dict["k"] as? String) else { return }
            self.handleKeyPress(index)
        }
    }

    // MARK: - Lifecycle

    public func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        contendingClient = false
        keyBindings = KeyBindings.load()
        startTunnels()

        await openDevice()
        HerdrHosts.shared.all.forEach(startLifecycleStream)
        await refresh()

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.config.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    public func stop() async {
        isRunning = false
        pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        lifecycles.values.forEach { $0.stop() }
        lifecycles.removeAll()
        statusStreams.values.forEach { $0.stop() }
        statusStreams.removeAll()
        tunnels.forEach { $0.stop() }
        tunnels = []
        HerdrHosts.shared.remotes = []
        remoteProblems = []
        lastFingerprint = nil

        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there.
        if device.isConnected {
            await allLightsOff()
            device.disconnect(reason: nil)
        }
        deviceConnected = false
        keyColors = [:]
        keyEffects = [:]
        aggregateState = nil
        agents = []
    }

    // MARK: - Device

    private func openDevice() async {
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            deviceName = device.info?.product ?? "Work Louder device"
            lastError = nil
        } catch {
            deviceConnected = false
            let message = error.localizedDescription
            if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
                permissionDenied = true
                if !warnedPermission { warnedPermission = true; lastError = message }
            } else {
                lastError = message
            }
            scheduleReopen()
            return
        }

        if let version = try? await device.callAsync("sys.version"),
           let dict = version as? [String: Any],
           let text = dict["version"] as? String {
            firmware = text
        }
        if let status = try? await device.callAsync("device.status"),
           let dict = status as? [String: Any],
           let percent = dict["battery"] as? Int {
            let charging = (dict["is_charging"] as? Bool) == true
            battery = "\(percent)%\(charging ? " ⚡" : "")"
        }

        await ensureKeymap()
    }

    /// Per-key lighting only works on keys bound to `KV_OAI_AG*` on the active
    /// layer, and nothing reports a mismatch — `v.oai.thstatus` answers
    /// `{"ok":1}` for a key it cannot light. So check rather than assume.
    private func ensureKeymap() async {
        guard let layer = await KeymapManager.activeLayer(device) else {
            keymapReady = false
            lastError = "The pad did not say which layer it is on, so the keys were left alone."
            return
        }
        activeLayer = layer
        do {
            if config.manageKeymap {
                _ = try await KeymapManager.apply(device, layer: layer)
                keymapReady = true
            } else {
                let cfg = try await KeymapManager.read(device)
                keymapReady = KeymapManager.isAgentKeymapApplied(cfg, layer: layer)
                if !keymapReady {
                    lastError = "The agent keys and the stack key are not bound to KV_OAI_AG00..AG06 on layer \(layer + 1), so per-key colours will do nothing."
                }
            }
        } catch {
            keymapReady = false
            lastError = "Keymap: \(error.localizedDescription)"
        }
    }

    /// The pad's own layer switcher moves which layer is live, and the agent
    /// keycodes only work on the live one. Without this a switch on the
    /// hardware leaves a pad that lights nothing and answers nothing, with no
    /// error anywhere - the same silence that made the wrong layer so hard to
    /// find in the first place.
    private func followLayerSwitch() async {
        guard deviceConnected, let layer = await KeymapManager.activeLayer(device),
              layer != activeLayer
        else { return }
        await ensureKeymap()
        // The pad keeps no lighting across a layer switch, so repaint even
        // when the picture itself has not changed.
        lastFingerprint = nil
    }

    private func scheduleReopen() {
        guard isRunning, reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRunning else { return }
                if self.deviceConnected { break }
                await self.openDevice()
                if self.deviceConnected {
                    await self.forceRepaint()
                    break
                }
            }
            self?.reopenTask = nil
        }
    }

    // MARK: - Herdr events

    /// Remotes come from the same config file as the keys, so they too follow
    /// an off/on toggle. Their agents join the list after this Mac's.
    private func startTunnels() {
        tunnels = HerdrRemote.load().map(HerdrTunnel.init(remote:))
        HerdrHosts.shared.remotes = tunnels.map(\.host)
        for tunnel in tunnels {
            // Up or down, the agent list just changed.
            tunnel.onChange = { [weak self] in self?.schedule() }
            tunnel.start()
        }
    }

    /// One per server. A remote's stream fails while its tunnel is down and
    /// keeps retrying, which is what picks the remote back up once it is.
    private func startLifecycleStream(_ host: HerdrHost) {
        guard isRunning, HerdrHosts.shared.all.contains(host) else { return }
        let stream = HerdrEventStream(subscriptions: [
            ["type": "pane.created"],
            ["type": "pane.closed"],
            ["type": "pane.exited"],
            ["type": "pane.agent_detected"],
        ], on: host)
        stream.onEvent = { [weak self] _ in self?.schedule() }
        stream.onReady = { [weak self] in self?.schedule() }
        stream.onClosed = { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.lifecycles[host] = nil
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.startLifecycleStream(host)
            }
        }
        lifecycles[host] = stream.start()
    }

    /// One dedicated stream per agent pane: a subscription owns its connection
    /// and cannot be extended after the fact.
    private func reconcileStatusStreams(_ agents: [HerdrAgent]) {
        let wanted = Set(agents.compactMap(\.paneKey))
        for (key, stream) in statusStreams where !wanted.contains(key) {
            stream.stop()
            statusStreams.removeValue(forKey: key)
        }
        for agent in agents {
            guard let key = agent.paneKey, let paneID = agent.paneID, statusStreams[key] == nil
            else { continue }
            let stream = HerdrEventStream(subscriptions: [
                ["type": "pane.agent_status_changed", "pane_id": paneID],
            ], on: agent.host)
            stream.onEvent = { [weak self] _ in self?.schedule() }
            stream.onClosed = { [weak self] _ in
                self?.statusStreams.removeValue(forKey: key)
            }
            statusStreams[key] = stream.start()
        }
    }

    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.config.debounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.debounceTask = nil
            await self.refresh()
        }
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lastFingerprint = nil
        await refresh()
    }

    private func refresh() async {
        guard isRunning else { return }
        await followLayerSwitch()

        let listed: [HerdrAgent]
        do {
            let result = try await HerdrClient.listAllAgents()
            listed = result.agents
            // This Mac's server failing while a remote answers still leaves
            // agents to show, so it is an error line, not an early return.
            lastError = result.failures[.local]?.localizedDescription
            remoteProblems = remoteProblemLines(result.failures)
        } catch {
            lastError = error.localizedDescription
            remoteProblems = remoteProblemLines([:])
            return
        }
        reconcileStatusStreams(listed)
        refreshReviewPanes()
        let fetched = BhoteReview.resolve(listed, reviewPanes: reviewPanes)
        agents = fetched

        // Day or night is decided per paint; the fingerprint carries the
        // brightness, so the poll repaints when the clock crosses the line.
        let config = self.config.lit()
        let now = Date()
        var since: [String: Date] = [:]
        for agent in fetched where agent.status == "working" {
            guard let key = agent.paneKey else { continue }
            since[key] = workingSince[key] ?? now
        }
        workingSince = since
        let state = StatusMapper.aggregate(fetched, config)
        // Macro and voice keys share ids, so the binding decides each key's
        // light: configured text wins, the wide key falls back to voice.
        let flexKeys = keyBindings.flexKeys.map { key -> OAI.Thread in
            if keyBindings.text(for: key) != nil || keyBindings.action(for: key) != nil {
                return boundThread(key, config)
            }
            if keyBindings.voiceKeys.contains(key) {
                return StatusMapper.voiceThread(id: key, active: voiceActive, config)
            }
            return OAI.Thread(id: key, brightness: 0, effect: .off)
        }
        // Text and keystrokes beat the built-in role at the light too, or a
        // key that now types a macro would still wear the stack key's violet.
        let bound = keyBindings.textKeys.union(keyBindings.actionKeys)
        // A key claimed for agents drops its built-in light with its role.
        let builtIns = [StatusMapper.stackThread(open: stackPanelOpen, config),
                        StatusMapper.tabCycleThread(config),
                        StatusMapper.landThread(open: landPanelOpen, config)]
            .filter { keyBindings.keepsBuiltInRole($0.id) }
        let threads = (StatusMapper.threads(
            for: fetched, keys: keyBindings.agentKeys,
            workingSince: fetched.map { $0.paneKey.flatMap { since[$0] } }, config)
            + builtIns
            + flexKeys)
            .map { bound.contains($0.id) ? boundThread($0.id, config) : $0 }

        // Fingerprint the whole rendered picture, not just the aggregate, so
        // one agent changing still repaints when the worst state has not.
        let fingerprint = threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1)"
        }.joined(separator: "|") + "|agg:\(state ?? "-")"

        publishKeyState(threads)
        aggregateState = state

        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(state: state, threads: threads)
    }

    /// The light for a key bound to a keystroke or a text macro.
    private func boundThread(_ key: Int, _ config: BridgeConfig) -> OAI.Thread {
        if let action = keyBindings.action(for: key) {
            return StatusMapper.actionThread(id: key, action: action, config)
        }
        return StatusMapper.macroThread(id: key, config)
    }

    /// Asks bhote which agents wait on you, at most every few seconds and off
    /// the main path. A change repaints.
    private func refreshReviewPanes() {
        guard !reviewFetching, Date().timeIntervalSince(reviewFetchedAt) > 4 else { return }
        reviewFetching = true
        let remotes = HerdrHosts.shared.remotes.compactMap(\.name)
        Task { [weak self] in
            let panes = await BhoteReview.fetch(remoteNames: remotes)
            guard let self else { return }
            self.reviewFetching = false
            self.reviewFetchedAt = Date()
            if let panes, panes != self.reviewPanes {
                self.reviewPanes = panes
                self.schedule()
            }
        }
    }

    /// The tunnel's own reason wins: "connection refused" on the local end of
    /// a tunnel that is not up says nothing about why.
    private func remoteProblemLines(_ failures: [HerdrHost: Error]) -> [String] {
        tunnels.compactMap { tunnel in
            if let reason = tunnel.lastError { return "\(tunnel.remote.name): \(reason)" }
            if let error = failures[tunnel.host] { return "\(tunnel.remote.name): \(error.localizedDescription)" }
            return nil
        }
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        for thread in threads {
            guard let packed = thread.color, (thread.brightness ?? 0) > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
        }
        keyColors = colors
        keyEffects = effects
    }

    private static let log = Logger(subsystem: "cc.worklouder.wlkit", category: "bridge")

    private func apply(state: String?, threads: [OAI.Thread]) async {
        guard deviceConnected else { return }
        do {
            let changed = threads.filter { sentThreads[$0.id] != $0 }
            if !changed.isEmpty {
                _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(changed))
                for thread in changed { sentThreads[thread.id] = thread }
            }
            let config = self.config.lit()
            let zone = StatusMapper.zone(for: state, config) ?? .dark
            _ = try await device.callAsync(
                OAI.methodRGBConfig,
                params: OAI.rgbConfigParams(
                    keys: config.driveBacklight ? zone : .dark,
                    ambient: zone
                )
            )
            let lit = threads.filter { ($0.brightness ?? 0) > 0 }
                .map { "\($0.id)=\(String(format: "%06X", $0.color ?? 0))" }.joined(separator: " ")
            Self.log.notice("painted \(state ?? "-", privacy: .public): \(lit, privacy: .public)")
        } catch {
            Self.log.error("paint failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            lastFingerprint = nil   // repaint on the next tick
        }
    }

    /// Thread state paints over zone state, so clearing the zones alone leaves
    /// the pad lit. Both have to go.
    private func allLightsOff() async {
        let threads = (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
        _ = try? await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        _ = try? await device.callAsync(
            OAI.methodRGBConfig,
            params: OAI.rgbConfigParams(keys: .dark, ambient: .dark)
        )
    }

    // MARK: - Key presses

    /// Every bound key arrives here. Which key does what is the one place that
    /// has to agree with `Pad`, so keep the dispatch in a single switch.
    public func handleKeyPress(_ index: Int) {
        if onKeyIntercept?(index) == true { return }
        // Configured text wins over every built-in role. That is what lets the
        // wide key be traded for a macro, and what makes the stack and land
        // keys useful on a machine with no GitButler to drive.
        if let text = keyBindings.text(for: index) {
            Task { await injectPrompt(text) }
        } else if let action = keyBindings.action(for: index) {
            onAction?(action)
        } else if let slot = keyBindings.agentSlot(for: index) {
            // Ahead of the built-in roles: "agents" may claim their keys.
            Task { await focusSlot(slot) }
        } else if index == Pad.stackKeyID {
            onStackKey?()
        } else if index == Pad.tabCycleKeyID {
            Task { await cycleTabs() }
        } else if index == Pad.landKeyID {
            onLandKey?()
        } else if keyBindings.voiceKeys.contains(index) {
            onVoiceKey?()
        } else if index == Pad.dialUpID || index == Pad.dialDownID {
            let step = index == Pad.dialUpID ? 1 : -1
            switch keyBindings.dial {
            case .effort: onDial?(step)
            case .volume: onAction?(step > 0 ? .volumeUp : .volumeDown)
            }
        } else if let direction = Pad.JoystickDirection(keyID: index) {
            switch keyBindings.joystick {
            case .model:
                onJoystick?(direction)
            case .agents:
                // East and west stay free: a list walked with two directions
                // has nothing for the other two to mean.
                switch direction {
                case .north: Task { await focusAdjacentAgent(1) }
                case .south: Task { await focusAdjacentAgent(-1) }
                case .east, .west: break
                }
            }
        }
    }

    /// Types a macro string into the focused agent's prompt, unsubmitted —
    /// the human still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let pane = agent.paneID
            else {
                lastError = "Nothing has focus in Herdr right now."
                return
            }
            try await HerdrClient.sendText(paneID: pane, text: text, on: agent.host)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the voice key. Same contract as `setStackPanelOpen`.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await forceRepaint()
    }

    /// Lets app-layer features that fail outside the bridge surface their
    /// error where the menu already shows the bridge's own.
    public func noteError(_ message: String) {
        lastError = message
    }

    /// Advances the focused workspace to its next tab, wrapping.
    public func cycleTabs() async {
        do {
            try await HerdrClient.cycleTabs(on: HerdrHosts.shared.active)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the stack key. Called by the app when the window opens or
    /// closes, so the key reflects what is actually on screen.
    public func setStackPanelOpen(_ open: Bool) async {
        guard stackPanelOpen != open else { return }
        stackPanelOpen = open
        await forceRepaint()
    }

    /// Repaints the land key. Same contract as `setStackPanelOpen`.
    public func setLandPanelOpen(_ open: Bool) async {
        guard landPanelOpen != open else { return }
        landPanelOpen = open
        await forceRepaint()
    }

    /// Slot N is the Nth agent key (`keyBindings.agentKeys[N]`) — the
    /// same mapping the lighting uses, which is what makes the key you look at
    /// the key you press.
    ///
    /// Herdr selects the pane but leaves the terminal wherever it was in the
    /// window order, so an agent key pressed from a browser used to move a
    /// cursor you could not see. The terminal comes forward with it.
    public func focusSlot(_ index: Int) async {
        // An empty slot used to swallow the press in silence, which reads as a
        // dead key rather than an unused one - say so instead.
        guard index >= 0, index < agents.count else {
            lastError = agents.isEmpty
                ? "No agents in Herdr right now."
                : "Nothing on that key — Herdr has \(agents.count) agent\(agents.count == 1 ? "" : "s")."
            return
        }
        let agent = agents[index]
        guard let target = agent.focusTarget else {
            lastError = "Herdr gave no pane for \(agent.shortName)."
            return
        }
        do {
            // `pane.focus` is what actually moves the rendered view; a pane id
            // is what it takes, so `agent.focus` only covers the fallback case
            // where Herdr reported no pane and `target` is a terminal id.
            if let pane = agent.paneID {
                try await HerdrClient.focusPane(pane, on: agent.host)
            } else {
                try await HerdrClient.focusAgent(target, on: agent.host)
            }
            // What the dial, the macros and tab cycling act on from now on.
            HerdrHosts.shared.active = agent.host
            raiseTerminal()
            try await switchClientMachine(to: index, agent: agent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves focus along Herdr's agent list, wrapping: +1 for the next
    /// agent, -1 for the previous one.
    ///
    /// Where focus is comes from Herdr rather than from anything remembered
    /// here, so a jump made with an agent key, or with the mouse, is the place
    /// the next deflection steps from. Focus outside the list — a browser, a
    /// pane with no agent — starts at whichever end the direction implies.
    public func focusAdjacentAgent(_ step: Int) async {
        guard !agents.isEmpty else {
            lastError = "No agents in Herdr right now."
            return
        }
        let focused = try? await HerdrClient.focusedAgent()
        let current = focused?.paneKey.flatMap { key in
            agents.firstIndex { $0.paneKey == key }
        }
        let from = current ?? (step > 0 ? -1 : 0)
        await focusSlot((from + step + agents.count) % agents.count)
    }

    /// Puts the Herdr client on the agent's machine.
    ///
    /// A client with machines added shows one machine at a time, and which one
    /// is the client's business: the socket API has no call for it, and
    /// `pane.focus` only moves a server's focus - so a key for an agent on the
    /// machine not on screen changed nothing you could see. The client's own
    /// `focus_agent` binding does switch machine; it is keyed by agent panel
    /// row, which follows the same order as the keys (this Mac, then each
    /// remote, each in sidebar order).
    ///
    /// Only rows 1 to 9 have a binding, and the panel's order is Herdr's, so
    /// the row is used to land on the right *machine*, and `pane.focus` right
    /// after it picks the exact pane. Any row of the same machine will do for
    /// an agent past row 9.
    private func switchClientMachine(to index: Int, agent: HerdrAgent) async throws {
        guard !HerdrHosts.shared.remotes.isEmpty, let onFocusAgentRow,
              let row = ([index] + Array(agents.indices))
                .first(where: { $0 < 9 && agents[$0].host == agent.host }),
              await waitForTerminal()
        else { return }
        Self.log.notice("slot \(index) on \(agent.host.name ?? "local", privacy: .public): herdr row \(row + 1), then pane \(agent.paneID ?? "-", privacy: .public)")
        onFocusAgentRow(row + 1)
        // Let the client act on the keystroke before the server-side focus
        // lands, or the row's agent wins over the one that was asked for.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let pane = agent.paneID {
            try await HerdrClient.focusPane(pane, on: agent.host)
        }
    }

    /// True once the terminal is the active app, for up to half a second: a
    /// keystroke posted before that goes to whatever was in front.
    private func waitForTerminal() async -> Bool {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: terminalBundleID).first
        else { return false }
        for _ in 0..<20 {
            if app.isActive { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return app.isActive
    }

    private var terminalBundleID: String {
        ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerminalBundleID
    }

    /// The app Herdr's panes live in. Override with `WL_TERMINAL_BUNDLE_ID` if
    /// they live somewhere other than Ghostty.
    public static let defaultTerminalBundleID = "com.mitchellh.ghostty"

    /// Brings the terminal forward unless it is already the active app.
    ///
    /// Nothing is ever launched: the agent whose key was pressed is running in
    /// a pane of a terminal that is by definition already up, so a terminal
    /// that is not running means the bundle id is wrong, and opening a fresh
    /// window would not be what the key meant. macOS may refuse a background
    /// app's `activate` outright, which is what the second attempt is for —
    /// `openApplication` on an already-running app raises it the way `open -a`
    /// does.
    private func raiseTerminal() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: terminalBundleID).first
        else { return }
        guard !app.isActive else { return }
        if app.activate(options: []) { return }
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
