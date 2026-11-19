import Foundation
import VoicePointerCore
import CAudioMeterSupport

@MainActor
protocol MicrophoneLevelMonitoring: AnyObject {
    var level: Float { get }
    /// The level the HUD draws: 0...1, already on a perceptual scale (0 = quiet room, 1 = this speaker's loud syllables).
    var displayLevel: Float { get }
    var isRunning: Bool { get }
    var hasStartIntent: Bool { get }
    func start()
    func stop()
}

extension MicrophoneLevelMonitoring {
    var displayLevel: Float { Float(RadialHUDView.normalizedAudioLevel(CGFloat(level))) }
}

/// Turns the raw meter level into what the HUD draws (2026-11-10, Ken: the bars in the middle still do not move).
/// Measured on Ken's built-in microphone: whole dictations peak at 0.004-0.02 (about -48 to -34 dB) in both meter modes,
/// under the old fixed -36 dB floor, so the bars stood still. Instead of a fixed window, follow this speaker:
/// the quiet floor falls at once to quiet moments and creeps up slowly; the loudest recent speech jumps up at once and
/// eases back down; the drawn level is where the voice sits between the two. Only these two numbers are kept, in memory.
struct VoiceLevelShaper {
    private(set) var floorDb: Double = -66
    private(set) var topDb: Double = -40
    private var lastTime: Double = 0

    mutating func next(_ raw: Float, now: Double) -> Float {
        let dt = lastTime == 0 ? 0.034 : min(max(now - lastTime, 0), 0.5)
        lastTime = now
        guard raw > 0 else { return 0 }      // no audio at all stays still; nothing is synthesized
        let db = 20 * log10(max(Double(raw), 1e-6))
        if db < floorDb {
            floorDb += (db - floorDb) * (1 - exp(-dt / 0.25))
        } else {
            floorDb += min(db - floorDb, 0.5 * dt)
        }
        floorDb = min(max(floorDb, -90), -30)
        topDb = db > topDb ? db : topDb - 2.0 * dt
        topDb = max(topDb, floorDb + 22)
        let gate = floorDb + 5
        let x = (db - gate) / max(topDb - gate, 6)
        return Float(pow(min(max(x, 0), 1), 0.85))
    }
}

struct MicrophoneLevelSummary: Equatable {
    let count: Int
    let p50: Float
    let p95: Float
    let maximum: Float

    init?(samples: [Float]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Float {
            let rank = max(0, Int(ceil(fraction * Double(sorted.count))) - 1)
            return sorted[min(rank, sorted.count - 1)]
        }
        count = sorted.count
        p50 = percentile(0.50)
        p95 = percentile(0.95)
        maximum = sorted[sorted.count - 1]
    }

    var runtimeFields: String {
        "count=\(count) p50=\(Self.format(p50)) p95=\(Self.format(p95)) max=\(Self.format(maximum))"
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4f", Double(value))
    }
}

private func makeAudioSession(
    levelBox: AudioLevelBuffer, generation: UInt64, deviceID: UInt32,
    failure: @escaping @Sendable (String) -> Void
) -> VPCAudioMeterSession {
    let handler: @Sendable (Float) -> Void = {
        InputDeviceRuntime.shared.confirmInputOpened(deviceID: deviceID)
        levelBox.set($0, generation: generation)
    }
    let failureHandler: @Sendable (String) -> Void = { reason in
        // Close writes synchronously on the audio notification thread, then
        // schedule at most one MainActor cleanup for this capture generation.
        if levelBox.invalidate(generation: generation) { failure(reason) }
    }
    let ring = DoubaoLearningAudioRing.shared
    return VPCAudioMeterSession(handler: handler, failureHandler: failureHandler,
        pcmEnabled: { ring.isArmed }, pcmHandler: { buffer, peak in ring.appendMeterBuffer(buffer, rawPeak: peak) })
}

/// AVAudioEngine can block inside input-node setup or start while the audio
/// route changes. Keep its entire lifecycle on one serial queue so the HUD's
/// MainActor is never held by Core Audio. The generation is invalidated before
/// an asynchronous stop is queued, so a late start cannot revive old levels.
private final class AudioMeterStartTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func claim() -> Bool {
        lock.withLock { if completed { return false }; completed = true; return true }
    }
}
private final class AudioMeterWorker: @unchecked Sendable {
    private let queue = VPCAudioControlQueue()
    private let intentLock = NSLock()
    private var desiredGeneration: UInt64 = 0 // intentLock-guarded
    private var session: VPCAudioMeterSession? // queue-confined

    func start(
        levelBox: AudioLevelBuffer,
        generation: UInt64,
        deviceID: UInt32,
        systemDefaultID: UInt32,
        nominalRate: Double,
        deviceFields: String,
        deviceUID: String,
        deviceClass: String,
        defaultClass: String,
        onFailure: @escaping @Sendable (String) -> Void,
        onResult: @escaping @Sendable (UInt64, Bool, String) -> Void
    ) {
        intentLock.withLock { desiredGeneration = generation }
        let ticket = AudioMeterStartTicket()
        let useEngine = UserDefaults.standard.string(forKey: "captureBackend") == "engine"
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(1500)) { [self] in
            guard ticket.claim(), isDesired(generation) else { return }
            intentLock.withLock { if desiredGeneration == generation { desiredGeneration = 0 } }
            RuntimeTrace.record("capture open backend=\(useEngine ? "engine" : "auhal") device=\(deviceClass) default=\(defaultClass) stage=start status=\(InputDeviceRuntime.noCallbacksStatus) hwRate=0 ch=0 firstCallbackMs=-1 firstNonzeroMs=-1")
            onResult(generation, false, "START_TIMEOUT")
        }
        queue.async { [self] in
            guard isDesired(generation) else { return }
            if let session {
                RuntimeTrace.record(session.diagnosticSnapshot())
            }
            session?.stop()
            if let session { RuntimeTrace.record(session.openDiagnostic()) }
            session = nil
            guard isDesired(generation) else { return }
            let candidate = makeAudioSession(
                levelBox: levelBox, generation: generation, deviceID: deviceID, failure: onFailure
            )
            candidate.inputDeviceID = deviceID
            candidate.systemDefaultInputID = systemDefaultID
            candidate.nominalSampleRate = nominalRate
            candidate.inputDiagnosticFields = deviceFields
            candidate.inputDeviceUID = deviceUID
            candidate.inputDeviceClass = deviceClass
            candidate.defaultDeviceClass = defaultClass
            candidate.useEngineBackend = useEngine
            guard isDesired(generation) else { return }
            var failure: NSString?
            var diagnostic: NSString?
            let startTime = DispatchTime.now().uptimeNanoseconds
            RuntimeTrace.record("audio meter start begin")
            let started = candidate.start(withFailure: &failure, diagnostic: &diagnostic)
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
            let deliver = ticket.claim()
            let stillDesired = isDesired(generation) && deliver
            if started && stillDesired {
                session = candidate
            } else {
                candidate.stop()
                if deliver { RuntimeTrace.record(candidate.openDiagnostic()) }
            }
            RuntimeTrace.record(
                "audio meter start end elapsedMs=\(elapsedMs) started=\(started) desired=\(stillDesired)"
            )
            if !started, let diagnostic { RuntimeTrace.record(String(diagnostic)) }
            if deliver { onResult(generation, started && stillDesired,
                     started ? String(diagnostic ?? "unknown") : String(failure ?? "unknown"))
            }
        }
    }

    func stop() {
        intentLock.withLock { desiredGeneration = 0 }
        queue.async { [self] in
            if let session {
                RuntimeTrace.record(session.diagnosticSnapshot())
            }
            session?.stop()
            if let session { RuntimeTrace.record(session.openDiagnostic()) }
            session = nil
        }
    }

    private func isDesired(_ generation: UInt64) -> Bool {
        intentLock.withLock { desiredGeneration == generation }
    }
}

/// Captures the system input stream and exposes a normalized 0...1 level for a
/// main-actor UI to poll. It deliberately reports zero until recording access
/// is granted; it never synthesizes a waveform when the microphone is absent.
@MainActor
final class MicrophoneLevelMonitor: MicrophoneLevelMonitoring {
    /// Frozen by the route admission before the HUD begins polling.
    static var usesRecognizerBus = true
    private var busOnly = true
    private var busIntent = false
    private let worker = AudioMeterWorker()
    private let levelBox = AudioLevelBuffer()
    private var activeAudioGeneration: UInt64 = 0
    private var summaryTask: Task<Void, Never>?
    private var summaryGeneration: UInt64?
    private var summarySamples: [Float] = []
    private var deviceObserver: (any NSObjectProtocol)?
    private var inventoryObserver: (any NSObjectProtocol)?
    private var openedDeviceID: UInt32 = 0
    private var openedNominalRate: Double = 0
    private var followsDefault = true
    /// Start-intent and permission-generation decisions live in this shared
    /// pure state type so the self-test exercises the exact gate production
    /// uses; this class only maps its effects onto AVAudioEngine work.
    private var gate = MicrophoneIntentGate()
    /// Reopens after a route change or a stretch of digital silence within one user-started capture (bounded).
    private var configurationReopens = 0
    /// How long the meter may read nothing but exact zeros before it is reopened.
    private var digitalSilenceNanoseconds: UInt64 = 500_000_000
    private var noCallbacksNanoseconds: UInt64 = 300_000_000
    private var stalledNanoseconds: UInt64 = 500_000_000

    /// A normalized peak/RMS hybrid in the range 0...1. While a recognizer is capturing, the level of the
    /// audio it is actually receiving counts too: on a Bluetooth headset that is switching to its call
    /// profile this monitor's own engine can read digital silence for a whole capture while recognition
    /// hears the person fine. Nothing is synthesized; with no recognizer capturing only this engine speaks.
    var level: Float {
        if busOnly { return CaptureLevelBus.shared.recent() ?? 0 }
        let own = levelBox.get()
        guard let recognized = CaptureLevelBus.shared.recent() else { return own }
        return max(own, recognized)
    }
    /// What the HUD draws, through `VoiceLevelShaper` (same for the recognizer's audio and 豆包 mode's own meter).
    /// Only the drawn number changes; nothing is recorded or kept, and the speech summary still uses `level`.
    private var shaper = VoiceLevelShaper()
    var displayLevel: Float { shaper.next(level, now: ProcessInfo.processInfo.systemUptime) }
    var sampleCount: UInt64 { busOnly ? CaptureLevelBus.shared.sampleCount() : levelBox.sampleCount() }
    var isRunning: Bool { busOnly ? busIntent && CaptureLevelBus.shared.activeCaptures > 0 : gate.isEngineRunning }
    var hasStartIntent: Bool { busOnly ? busIntent : gate.desiredRunning }

    func start() {
        guard !hasStartIntent else { return }
        busOnly = Self.usesRecognizerBus
        if busOnly {
            busIntent = true
            activeAudioGeneration &+= 1
            startLevelSummary(for: activeAudioGeneration)
            RuntimeTrace.record("microphone monitor source=captureBus")
            return
        }
        if deviceObserver == nil {
            deviceObserver = NotificationCenter.default.addObserver(forName: InputDeviceRuntime.changed, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.gate.desiredRunning else { return }
                    self.worker.stop(); self.openEngine()
                }
            }
        }
        if inventoryObserver == nil {
            inventoryObserver = NotificationCenter.default.addObserver(forName: InputDeviceInventory.changed,
                object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.gate.desiredRunning, self.activeAudioGeneration != 0 else { return }
                    let currentID = InputConfigurationPolicy.captureDevice(configured: self.openedDeviceID,
                        followsDefault: self.followsDefault, systemDefault: InputDeviceInventory.defaultInputID(),
                        configuredAvailable: InputDeviceInventory.hasInputStreams(self.openedDeviceID))
                    let rate = InputDeviceInventory.nominalRate(currentID)
                    guard currentID != self.openedDeviceID ||
                        (rate > 0 && self.openedNominalRate > 0 && abs(rate - self.openedNominalRate) >= 1) else { return }
                    InputDeviceRuntime.shared.beginIntent(resetFallback: false)
                    self.audioConfigurationFailed("AUDIO_ROUTE_CHANGED", generation: self.activeAudioGeneration)
                }
            }
        }
        configurationReopens = 0
        CaptureLevelBus.shared.invalidate()
        gate.setPermission(Self.systemRecordPermission())
        apply(gate.beginIntent())
    }

    func stop() {
        busIntent = false
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver); self.deviceObserver = nil }
        if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver); self.inventoryObserver = nil }
        finishLevelSummary()
        activeAudioGeneration = 0
        levelBox.endCapture()
        let effect = gate.endIntent()
        // A failed start may already have cleared the gate's running bit.
        worker.stop()
        if effect == .closeEngine {
            RuntimeTrace.record("microphone monitor stopped samples=\(sampleCount)")
        }
    }

    private func apply(_ effect: MicrophoneIntentGate.Effect) {
        switch effect {
        case .none:
            break
        case .denied:
            RuntimeTrace.record("microphone monitor permission=denied")
        case .requestPermission(let requestGeneration):
            RuntimeTrace.record("microphone monitor permission=requested")
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.gate.setPermission(Self.systemRecordPermission())
                    self.apply(self.gate.permissionRequestResolved(
                        requestGeneration: requestGeneration,
                        granted: granted
                    ))
                }
            }
        case .openEngine:
            openEngine()
        case .closeEngine:
            finishLevelSummary()
            worker.stop()
            RuntimeTrace.record("microphone monitor stopped samples=\(sampleCount)")
        }
    }

    private func openEngine() {
        let generation = levelBox.beginCapture()
        activeAudioGeneration = generation
        let selection = InputDeviceRuntime.shared.selection()
        guard selection.reason != "failedUnavailable" else {
            activeAudioGeneration = 0; levelBox.endCapture(); worker.stop()
            gate.engineDidFailToStart(); InputDeviceRuntime.shared.reportOpenFailure(); return
        }
        openedDeviceID = selection.chosen?.id ?? 0
        let bluetooth = selection.chosen?.kind == .bluetooth
        digitalSilenceNanoseconds = bluetooth ? 2_000_000_000 : 500_000_000
        noCallbacksNanoseconds = bluetooth ? 2_500_000_000 : 300_000_000
        stalledNanoseconds = bluetooth ? 2_500_000_000 : 500_000_000
        openedNominalRate = InputDeviceInventory.nominalRate(openedDeviceID)
        followsDefault = selection.chosen?.kind != .builtin && !InputConfigurationPolicy.shouldSetDevice(chosen: openedDeviceID,
            systemDefault: selection.systemDefault?.id ?? InputDeviceInventory.defaultInputID())
        worker.start(
            levelBox: levelBox,
            generation: generation,
            deviceID: selection.chosen?.id ?? 0,
            systemDefaultID: selection.systemDefault?.id ?? InputDeviceInventory.defaultInputID(),
            nominalRate: openedNominalRate,
            deviceFields: InputDeviceInventory.diagnosticFields(for: openedDeviceID),
            deviceUID: selection.chosen?.captureUID ?? "",
            deviceClass: selection.chosen?.kind.captureLogClass ?? "other",
            defaultClass: selection.systemDefault?.kind.captureLogClass ?? "other",
            onFailure: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.audioConfigurationFailed(reason, generation: generation)
                }
            },
            onResult: { [weak self] completedGeneration, started, detail in
                Task { @MainActor [weak self] in
                    guard let self, self.activeAudioGeneration == completedGeneration else { return }
                    if started {
                        self.startLevelSummary(for: completedGeneration)
                        RuntimeTrace.record("microphone monitor started format=\(detail) policy=\(selection.policy.rawValue) default=\(selection.systemDefault?.kind.rawValue ?? "unknown")")
                    } else {
                        self.activeAudioGeneration = 0
                        self.levelBox.endCapture()
                        self.worker.stop()
                        RuntimeTrace.record("microphone monitor failed error=\(detail)")
                        if self.gate.desiredRunning,
                           InputDeviceRuntime.shared.fallback(reason: "startFailed", atMs: 0) != nil { return }
                        self.gate.engineDidFailToStart()
                        InputDeviceRuntime.shared.reportOpenFailure()
                    }
                }
            }
        )
    }

    private func audioConfigurationFailed(_ reason: String, generation: UInt64) {
        guard activeAudioGeneration == generation else { return }
        finishLevelSummary()
        activeAudioGeneration = 0
        levelBox.endCapture()
        worker.stop()
        // A Bluetooth headset (AirPods) switches to its microphone profile right after dictation starts,
        // which changes the audio route under the running engine. While the user is still dictating,
        // reopen on the new route instead of leaving the meter at zero for the rest of the capture.
        if gate.desiredRunning, configurationReopens < 2 {
            configurationReopens += 1
            RuntimeTrace.record("microphone monitor route changed; reopening attempt=\(configurationReopens)")
            scheduleReopen()
            return
        }
        gate.engineDidFailToStart()
        RuntimeTrace.record("microphone monitor configuration failed error=\(reason)")
    }

    private func scheduleReopen() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.gate.desiredRunning, self.activeAudioGeneration == 0 else { return }
            self.openEngine()
        }
    }

    /// A Bluetooth headset still switching to its call profile hands the meter buffers of exact zeros
    /// (AirPods at 24 kHz: 4 of 7 captures read zero from start to end). With no recognizer capturing,
    /// whose level would be shown instead, the meter is the ripple's only source, so reopen it on the
    /// settled route rather than leave it flat for the whole capture. Bounded like a route change.
    private func reopenAfterDigitalSilence(generation: UInt64) {
        guard activeAudioGeneration == generation, gate.desiredRunning,
              CaptureLevelBus.shared.activeCaptures == 0 else { return }
        guard InputDeviceRuntime.shared.fallback(reason: "allZero", atMs: digitalSilenceNanoseconds / 1_000_000) != nil else {
            InputDeviceRuntime.shared.reportOpenFailure()
            finishLevelSummary(); activeAudioGeneration = 0
            levelBox.endCapture(); worker.stop(); gate.engineDidFailToStart()
            return
        }
        finishLevelSummary()
        activeAudioGeneration = 0
        levelBox.endCapture()
        worker.stop()
        // The shared selection notification opens both meter and learning capture on the new device.
    }

    /// Samples only the scalar level at 30 Hz while the user-initiated capture
    /// is active. The sample series stays in memory and only numeric session
    /// percentiles are written when capture ends; audio and recognized text
    /// are never included.
    private func startLevelSummary(for generation: UInt64) {
        finishLevelSummary()
        summaryGeneration = generation
        summarySamples.removeAll(keepingCapacity: true)
        let firstCallbackCount = sampleCount
        var lastSampleCount = firstCallbackCount
        var silentSince: UInt64?
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var lastOwnCount = firstCallbackCount
        var lastCallbackAt = startedAt
        var heard = false
        summaryTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled,
                  self.activeAudioGeneration == generation {
                do {
                    try await Task.sleep(for: .milliseconds(34))
                } catch {
                    break
                }
                guard !Task.isCancelled,
                      self.activeAudioGeneration == generation else { break }
                let currentSampleCount = self.sampleCount
                if self.busOnly {
                    if currentSampleCount > lastSampleCount {
                        self.summarySamples.append(self.level)
                        lastSampleCount = currentSampleCount
                    }
                    continue
                }
                let ownCount = self.levelBox.sampleCount()
                let now = DispatchTime.now().uptimeNanoseconds
                if ownCount != lastOwnCount { lastOwnCount = ownCount; lastCallbackAt = now }
                if self.level > 0 { heard = true }
                if !heard, CaptureLevelBus.shared.activeCaptures == 0,
                   (ownCount == firstCallbackCount ? now - startedAt >= self.noCallbacksNanoseconds : now - lastCallbackAt >= self.stalledNanoseconds) {
                    let reason = "noCallbacks"
                    if reason == "noCallbacks" {
                        RuntimeTrace.record("capture start failed stage=start status=\(InputDeviceRuntime.noCallbacksStatus)")
                    }
                    if InputDeviceRuntime.shared.fallback(reason: reason, atMs: (now - startedAt) / 1_000_000) != nil { return }
                    if reason == "noCallbacks" {
                        self.finishLevelSummary(); self.activeAudioGeneration = 0
                        self.levelBox.endCapture(); self.worker.stop(); self.gate.engineDidFailToStart()
                        InputDeviceRuntime.shared.reportOpenFailure()
                        return
                    }
                }
                if currentSampleCount > lastSampleCount {
                    self.summarySamples.append(self.level)
                    lastSampleCount = currentSampleCount
                }
                // Buffers are arriving but every one is exact zeros: see `reopenAfterDigitalSilence`.
                if self.level > 0 || self.levelBox.sampleCount() &- firstCallbackCount < 3 {
                    silentSince = nil
                } else if let since = silentSince {
                    if DispatchTime.now().uptimeNanoseconds &- since >= self.digitalSilenceNanoseconds {
                        silentSince = nil
                        self.reopenAfterDigitalSilence(generation: generation)
                    }
                } else {
                    silentSince = startedAt
                }
            }
        }
    }

    private func finishLevelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        guard summaryGeneration != nil else { return }
        summaryGeneration = nil

        let values = summarySamples
        summarySamples.removeAll(keepingCapacity: true)
        guard let summary = MicrophoneLevelSummary(samples: values) else { return }
        // A down-swipe needs to know whether anyone spoke (see `ClearSwipePolicy`).
        GestureSpeechActivity.shared.recordCapture(peakLevel: summary.maximum)
        RuntimeTrace.record(
            "microphone level summary method=poll34ms \(summary.runtimeFields)"
        )
    }

    private static func systemRecordPermission() -> MicrophoneIntentGate.Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .denied
        }
    }
}
