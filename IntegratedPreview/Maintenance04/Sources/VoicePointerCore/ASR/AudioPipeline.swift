@preconcurrency import AVFoundation
import Foundation
import CAudioMeterSupport
import AudioToolbox

final class OwnedPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(copying source: AVAudioPCMBuffer) throws {
        guard source.frameLength > 0 else {
            throw TrialCoreError.invalid("AUDIO_BUFFER_EMPTY")
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            throw TrialCoreError.invalid("AUDIO_ALLOCATION_FAILED")
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == targetBuffers.count else {
            throw TrialCoreError.invalid("AUDIO_BUFFER_LAYOUT_CHANGED")
        }
        for index in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[index].mData,
                  let targetData = targetBuffers[index].mData else {
                throw TrialCoreError.invalid("AUDIO_BUFFER_COPY_FAILED")
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard byteCount >= 0 else {
                throw TrialCoreError.invalid("AUDIO_BUFFER_COPY_FAILED")
            }
            guard byteCount <= Int(targetBuffers[index].mDataByteSize) else {
                throw TrialCoreError.invalid("AUDIO_BUFFER_COPY_FAILED")
            }
            memcpy(targetData, sourceData, byteCount)
            targetBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        buffer = copy
    }

    convenience init?(_ source: AVAudioPCMBuffer) {
        try? self.init(copying: source)
    }
}

final class BoundedPCMStream: @unchecked Sendable {
    let stream: AsyncThrowingStream<OwnedPCMBuffer, Error>
    private let continuation: AsyncThrowingStream<OwnedPCMBuffer, Error>.Continuation
    private let lock = NSLock()
    private var finished = false
    private var acceptedCount = 0

    var enqueuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedCount
    }

    init(capacity: Int = 32) {
        var captured: AsyncThrowingStream<OwnedPCMBuffer, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(max(1, capacity))) { continuation in
            captured = continuation
        }
        continuation = captured
    }

    @discardableResult
    func yield(_ buffer: OwnedPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        switch continuation.yield(buffer) {
        case .enqueued:
            acceptedCount += 1
            return true
        case .dropped:
            finished = true
            continuation.finish(throwing: TrialCoreError.invalid("INPUT_QUEUE_OVERFLOW"))
            return false
        case .terminated:
            finished = true
            return false
        @unknown default:
            finished = true
            continuation.finish(throwing: TrialCoreError.invalid("INPUT_QUEUE_OVERFLOW"))
            return false
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    func finish(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish(throwing: error)
    }
}

final class CapturedPCMStore: @unchecked Sendable {
    static let byteLimit = 64 * 1024 * 1024
    static let durationSeconds = 60.0
    let byteLimit: Int
    let durationSeconds: Double

    init(byteLimit: Int = CapturedPCMStore.byteLimit, durationSeconds: Double = CapturedPCMStore.durationSeconds) {
        self.byteLimit = byteLimit
        self.durationSeconds = durationSeconds
    }

    private let lock = NSLock()
    private var buffers: [OwnedPCMBuffer] = []
    private var totalBytes = 0
    private var totalFrames: Int64 = 0
    private var sourceFormat: AVAudioFormat?
    private var sealed = false
    private var durationReached = false
    private var terminalFailure: TrialCoreError?

    var failure: TrialCoreError? {
        lock.lock()
        defer { lock.unlock() }
        return terminalFailure
    }

    /// Whether capture stopped because the duration budget was filled (not an error).
    var didReachDurationLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return durationReached
    }

    func seal() {
        lock.lock()
        sealed = true
        lock.unlock()
    }

    func fail(_ error: TrialCoreError) {
        lock.withLock {
            if terminalFailure == nil { _ = failLocked(error) }
        }
    }

    private func failLocked(_ error: TrialCoreError) -> TrialCoreError {
        sealed = true
        terminalFailure = error
        return error
    }

    private func maxFrames(for format: AVAudioFormat) -> Int64? {
        guard format.sampleRate.isFinite, format.sampleRate > 0 else { return nil }
        let value = durationSeconds * format.sampleRate
        guard value.isFinite, value >= 0, value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded(.down))
    }

    private func sameSourceFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        abs(lhs.sampleRate - rhs.sampleRate) < 0.000001 &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }

    func acceptsFormat(_ format: AVAudioFormat) -> Bool {
        lock.withLock { sourceFormat.map { sameSourceFormat($0, format) } ?? true }
    }

    private func reserveLocked(for source: AVAudioPCMBuffer) throws -> (bytes: Int, frames: Int64) {
        guard !sealed else {
            throw terminalFailure ?? TrialCoreError.invalid("CAPTURE_CLOSED")
        }
        guard source.frameLength > 0, let limit = maxFrames(for: source.format) else {
            throw failLocked(.invalid("INPUT_DEVICE_FORMAT_UNAVAILABLE"))
        }
        if let sourceFormat {
            guard sameSourceFormat(sourceFormat, source.format) else {
                throw failLocked(.invalid("SOURCE_FORMAT_CHANGED"))
            }
        } else {
            sourceFormat = source.format
        }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let bytes = audioBuffers.reduce(into: 0) { result, audioBuffer in
            let next = Int(audioBuffer.mDataByteSize)
            if next < 0 || result > Int.max - next { result = Int.max } else { result += next }
        }
        let frames = Int64(source.frameLength)
        guard bytes <= byteLimit - totalBytes,
              frames <= limit - totalFrames else {
            throw failLocked(.invalid("CAPTURE_LIMIT_EXCEEDED"))
        }
        totalBytes += bytes
        totalFrames += frames
        return (bytes, frames)
    }

    @discardableResult
    func append(copying source: AVAudioPCMBuffer) throws -> OwnedPCMBuffer {
        lock.lock()
        do {
            _ = try reserveLocked(for: source)
            do {
                let owned = try OwnedPCMBuffer(copying: source)
                buffers.append(owned)
                lock.unlock()
                return owned
            } catch {
                totalBytes = max(0, totalBytes - sourceByteCount(source))
                totalFrames = max(0, totalFrames - Int64(source.frameLength))
                let failure = failLocked(.invalid("AUDIO_BUFFER_COPY_FAILED"))
                throw failure
            }
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func sourceByteCount(_ source: AVAudioPCMBuffer) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        return list.reduce(0) { partial, buffer in
            let bytes = Int(buffer.mDataByteSize)
            guard bytes >= 0, partial <= Int.max - bytes else { return Int.max }
            return partial + bytes
        }
    }

    @discardableResult
    func append(_ buffer: OwnedPCMBuffer) -> Bool {
        lock.lock()
        do {
            _ = try reserveLocked(for: buffer.buffer)
            buffers.append(buffer)
            lock.unlock()
            return true
        } catch {
            lock.unlock()
            return false
        }
    }

    /// Copies the first `frames` frames from `source` into `target` following the buffer-list
    /// layout. `mBytesPerFrame` is the format's frame stride, valid for interleaved and
    /// non-interleaved layouts alike. Returns false on any allocation/layout inconsistency.
    private func copyAudioBuffers(from source: AVAudioPCMBuffer, to target: AVAudioPCMBuffer, frames: Int64) -> Bool {
        let stride = source.format.streamDescription.pointee.mBytesPerFrame
        guard stride > 0 else { return false }
        let bytesPerFrame = UInt64(stride)
        let byteTotal = bytesPerFrame * UInt64(frames)
        guard byteTotal <= UInt64(Int.max), byteTotal <= UInt64(UInt32.max) else { return false }
        let bytes = Int(byteTotal)
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetList = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard sourceList.count == targetList.count, sourceList.count > 0 else { return false }
        for index in 0..<sourceList.count {
            guard let sourceData = sourceList[index].mData, let targetData = targetList[index].mData,
                  Int(sourceList[index].mDataByteSize) >= bytes,
                  Int(targetList[index].mDataByteSize) >= bytes else { return false }
            memcpy(targetData, sourceData, bytes)
            targetList[index].mDataByteSize = UInt32(bytes)
        }
        return true
    }

    /// Duration-aware append: copies at most the remaining duration budget from `source`
    /// (never mutating it). A normal 5-minute stop seals the store without a terminal
    /// failure; byte-cap overflow still fails with CAPTURE_LIMIT_EXCEEDED.
    @discardableResult
    func appendUntilDuration(copying source: AVAudioPCMBuffer) throws -> (buffer: OwnedPCMBuffer?, reachedLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if sealed {
            if let failure = terminalFailure { throw failure }
            if durationReached { return (nil, true) }
            throw TrialCoreError.invalid("CAPTURE_CLOSED")
        }
        // Same validation and failure codes as reserveLocked.
        guard source.frameLength > 0, let limit = maxFrames(for: source.format) else {
            throw failLocked(.invalid("INPUT_DEVICE_FORMAT_UNAVAILABLE"))
        }
        if let sourceFormat {
            guard sameSourceFormat(sourceFormat, source.format) else {
                throw failLocked(.invalid("SOURCE_FORMAT_CHANGED"))
            }
        } else {
            sourceFormat = source.format
        }
        let remaining = limit - totalFrames
        if remaining <= 0 {
            sealed = true
            durationReached = true
            return (nil, true)
        }
        // Cap at the remaining budget; use the original buffer when it already fits.
        let usedFrames = min(Int64(source.frameLength), remaining)
        let effective: AVAudioPCMBuffer
        if usedFrames == Int64(source.frameLength) {
            effective = source
        } else {
            guard let capped = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(usedFrames)) else {
                throw failLocked(.invalid("AUDIO_BUFFER_COPY_FAILED"))
            }
            capped.frameLength = AVAudioFrameCount(usedFrames)
            guard copyAudioBuffers(from: source, to: capped, frames: usedFrames) else {
                throw failLocked(.invalid("AUDIO_BUFFER_COPY_FAILED"))
            }
            effective = capped
        }
        let reservation = try reserveLocked(for: effective)
        let bytes = reservation.bytes
        let frames = reservation.frames
        do {
            let owned = try OwnedPCMBuffer(copying: effective)
            buffers.append(owned)
            if totalFrames == limit {
                sealed = true
                durationReached = true
            }
            return (owned, durationReached)
        } catch {
            // Roll back the reservation exactly, then record the copy failure.
            totalBytes = max(0, totalBytes - bytes)
            totalFrames = max(0, totalFrames - frames)
            throw failLocked(.invalid("AUDIO_BUFFER_COPY_FAILED"))
        }
    }

    func snapshot() -> [OwnedPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }

    func removeAll() {
        lock.lock()
        buffers.removeAll(keepingCapacity: false)
        totalBytes = 0
        totalFrames = 0
        sourceFormat = nil
        sealed = false
        durationReached = false
        terminalFailure = nil
        lock.unlock()
    }
}

final class CaptureSink: @unchecked Sendable {
    let store: CapturedPCMStore
    let input: BoundedPCMStream?
    private let lock = NSLock()
    private var closed = false
    private var appleStreaming: Bool
    private var failureHandler: (@Sendable (String) -> Void)?
    private let gracefulDurationLimit: Bool
    private let diagnosticsOnly: Bool
    let diagnostics = CaptureAudioDiagnostics()
    private var silenceGate: MicrophoneSilenceGate?
    private var silenceHandler: (@Sendable (String) -> Void)?
    private var recovering = false
    private var captureGeneration: UInt64 = 0
    var callbackGeneration: UInt64 { lock.withLock { captureGeneration } }
    func setSilenceHandler(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { silenceHandler = handler } }

    var hasAcceptedAudio: Bool { lock.withLock { silenceGate?.hasAudio ?? false } }
    var silenceDecision: MicrophoneSilenceGate.Decision { lock.withLock { silenceGate?.decision() ?? .waiting } }

    func beginCapture(now: UInt64 = DispatchTime.now().uptimeNanoseconds,
                      configuration: MicrophoneSilenceGate.Configuration = .init()) {
        lock.withLock { silenceGate = MicrophoneSilenceGate(now: now, configuration: configuration); recovering = false; captureGeneration &+= 1 }
        diagnostics.begin(now: now)
    }

    /// Invalidate a detached tap without discarding accepted audio or its silence history.
    func resumeCapture() { lock.withLock { captureGeneration &+= 1; recovering = false } }

    /// A timer is required for a device that never invokes the tap callback.
    func checkSilence(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        var callback: (@Sendable (String) -> Void)?
        var code: String?
        lock.withLock {
            guard !closed, !recovering, let gate = silenceGate, let failure = gate.decision(now: now).failureCode else { return }
            if let silenceHandler { recovering = true; callback = silenceHandler }
            else { rejectLocked(failure); callback = failureHandler }
            code = failure
        }
        if let code { callback?(code) }
    }

    private func rejectLocked(_ code: String) {
        closed = true
        appleStreaming = false
        let error = TrialCoreError.invalid(code)
        store.fail(error)
        input?.finish(throwing: error)
    }

    init(store: CapturedPCMStore, input: BoundedPCMStream?, gracefulDurationLimit: Bool = false, diagnosticsOnly: Bool = false) {
        self.store = store
        self.input = input
        self.gracefulDurationLimit = gracefulDurationLimit
        self.diagnosticsOnly = diagnosticsOnly
        appleStreaming = input != nil
    }

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    func ingest(_ source: AVAudioPCMBuffer, now: UInt64 = DispatchTime.now().uptimeNanoseconds, generation: UInt64? = nil) {
        guard lock.withLock({ !closed && !recovering && (generation == nil || generation == captureGeneration) }) else { return }
        let measurement = PCMBufferLevel.measure(source)
        diagnostics.record(source, measurement: measurement, now: now)
        // The HUD ripple shows the level of what the recognizer is actually hearing.
        CaptureLevelBus.shared.publish(measurement.level, now: now)
        var callback: (@Sendable (String) -> Void)?
        var failure: TrialCoreError?
        var durationLimitCode: String?
        lock.lock()
        guard !closed, !recovering, generation == nil || generation == captureGeneration else {
            lock.unlock()
            return
        }
        if var gate = silenceGate {
            guard measurement.supported else {
                rejectLocked("INPUT_BUFFER_FORMAT_UNSUPPORTED")
                callback = failureHandler
                lock.unlock()
                callback?("INPUT_BUFFER_FORMAT_UNSUPPORTED")
                return
            }
            let decision = gate.observe(peak: measurement.peak, now: now)
            silenceGate = gate
            if let code = decision.failureCode {
                if let silenceHandler { recovering = true; callback = silenceHandler }
                else { rejectLocked(code); callback = failureHandler }
                lock.unlock()
                callback?(code)
                return
            }
            if decision.blocksRecognition {
                lock.unlock()
                return
            }
        }
        // Release can beat the HUD's first 34ms poll. Preserve the recognizer's
        // actual numeric peak so a quick spoken send is never classified as silent.
        if diagnosticsOnly { lock.unlock(); return }
        // A route notification can race a callback. Seal before the store sees an
        // incompatible buffer: already captured speech must never become a failure.
        if !store.acceptsFormat(source.format) {
            closed = true; appleStreaming = false
            store.seal(); input?.finish()
            lock.unlock()
            RuntimeTrace.record("capture_route phase=sealed reason=formatChanged")
            NotificationCenter.default.post(name: InputDeviceRuntime.notice, object: nil,
                userInfo: ["message": "麦克风切换了，后面的话没录到"])
            return
        }
        do {
            let owned: OwnedPCMBuffer?
            let reachedLimit: Bool
            if gracefulDurationLimit {
                let result = try store.appendUntilDuration(copying: source)
                owned = result.buffer
                reachedLimit = result.reachedLimit
            } else {
                owned = try store.append(copying: source)
                reachedLimit = false
            }
            if let owned, appleStreaming, let input, !input.yield(owned) {
                let error = TrialCoreError.invalid("INPUT_QUEUE_OVERFLOW")
                appleStreaming = false
                input.finish(throwing: error)
            }
            if reachedLimit {
                closed = true
                appleStreaming = false
                input?.finish()
                callback = failureHandler
                durationLimitCode = "CAPTURE_DURATION_REACHED"
            }
        } catch let error as TrialCoreError {
            closed = true
            appleStreaming = false
            store.seal()
            input?.finish(throwing: error)
            callback = failureHandler
            failure = error
        } catch {
            let error = TrialCoreError.invalid("AUDIO_CAPTURE_FAILED")
            closed = true
            appleStreaming = false
            store.seal()
            input?.finish(throwing: error)
            callback = failureHandler
            failure = error
        }
        lock.unlock()
        if let failure {
            callback?(failure.description)
        } else if let durationLimitCode {
            callback?(durationLimitCode)
        }
    }

    func disableAppleStreaming() {
        lock.lock()
        appleStreaming = false
        input?.finish()
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if !closed, let gate = silenceGate, let code = gate.decision(final: true).failureCode {
            rejectLocked(code)
        }
        closed = true
        appleStreaming = false
        store.seal()
        input?.finish()
        lock.unlock()
    }

    func terminate(_ error: TrialCoreError) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        appleStreaming = false
        let handler = failureHandler
        store.fail(error)
        input?.finish(throwing: error)
        lock.unlock()
        handler?(error.description)
    }
}

/// The tap callback is deliberately made outside the MainActor. AVAudioEngine
/// invokes it on its realtime queue, so inheriting the isolation of
/// LiveAudioPipeline here causes Swift 6's runtime isolation trap.
typealias AudioTapCallback = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

enum AudioTapCallbackFactory {
    nonisolated static func make(sink: CaptureSink,
                                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> AudioTapCallback {
        let generation = sink.callbackGeneration
        return { buffer, _ in sink.ingest(buffer, now: now(), generation: generation) }
    }
}

private struct CaptureOpenFailure: Error, Sendable {
    let stage: String
    let status: Int32
}
private struct CaptureOpenInfo: @unchecked Sendable {
    let deviceID: UInt32
    let format: AVAudioFormat
}

/// A small lifecycle lock, separate from HAL. An independent deadline resumes
/// the awaiting actor even if the serial audio-control queue is blocked.
private final class CaptureOpenTicket: @unchecked Sendable {
    private enum State { case pending, installed, stopping, abandoned, closed }
    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<CaptureOpenInfo, any Error>?
    private var generation: UInt64?
    private var startedAt: UInt64 = 0
    private var firstCallbackMs: Int64 = -1
    private var firstNonzeroMs: Int64 = -1
    private var resolvedDeviceID: UInt32 = 0
    private var lastCallbackAt: UInt64 = 0
    private var exactZeroSince: UInt64?

    var isPending: Bool { lock.withLock { state == .pending } }
    func arm(_ continuation: CheckedContinuation<CaptureOpenInfo, any Error>) {
        let rejected = lock.withLock { () -> Bool in
            guard state == .pending else { return true }
            self.continuation = continuation
            return false
        }
        if rejected { continuation.resume(throwing: CancellationError()) }
    }
    func allowPCM(generation: UInt64) {
        lock.withLock {
            guard state == .pending else { return }
            self.generation = generation
            startedAt = DispatchTime.now().uptimeNanoseconds
            lastCallbackAt = startedAt
        }
    }
    func pcmGeneration() -> UInt64? {
        lock.withLock { state == .pending || state == .installed || state == .stopping ? generation : nil }
    }
    func notePCM(_ buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        let measurement = PCMBufferLevel.measure(buffer)
        let nonzero = measurement.peak > 0
        lock.withLock {
            lastCallbackAt = now
            if measurement.supported && measurement.peak == 0 {
                if exactZeroSince == nil { exactZeroSince = now }
            } else { exactZeroSince = nil }
            let delay = now >= startedAt ? Int64((now - startedAt) / 1_000_000) : 0
            if firstCallbackMs < 0 { firstCallbackMs = delay }
            if nonzero && firstNonzeroMs < 0 { firstNonzeroMs = delay }
        }
    }
    func setResolvedDevice(_ id: UInt32) { lock.withLock { resolvedDeviceID = id } }
    func sourceDeviceID() -> UInt32 { lock.withLock { resolvedDeviceID } }
    func healthFailure(bluetooth: Bool) -> String? {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            guard state == .installed, lastCallbackAt > 0 else { return nil }
            let noCallbacks: UInt64 = bluetooth ? 2_500_000_000 : 300_000_000
            let allZero: UInt64 = bluetooth ? 2_000_000_000 : 500_000_000
            if now >= lastCallbackAt, now - lastCallbackAt >= noCallbacks { return "noCallbacks" }
            if let exactZeroSince, now >= exactZeroSince, now - exactZeroSince >= allZero { return "allZero" }
            return nil
        }
    }
    func times() -> (Int64, Int64) { lock.withLock { (firstCallbackMs, firstNonzeroMs) } }
    @discardableResult
    func complete(_ result: Result<CaptureOpenInfo, CaptureOpenFailure>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<CaptureOpenInfo, any Error>? in
            guard state == .pending else { return nil }
            switch result { case .success: state = .installed; case .failure: state = .closed; generation = nil }
            let saved = self.continuation; self.continuation = nil
            return saved
        }
        guard let continuation else { return false }
        continuation.resume(with: result.mapError { $0 as any Error })
        return true
    }
    @discardableResult
    func abandon(_ failure: CaptureOpenFailure) -> Bool {
        let result = lock.withLock { () -> (Bool, CheckedContinuation<CaptureOpenInfo, any Error>?) in
            guard state == .pending else { return (false, nil) }
            state = .abandoned; generation = nil
            let saved = continuation; continuation = nil
            return (true, saved)
        }
        result.1?.resume(throwing: failure)
        return result.0
    }
    func beginStop() -> Bool {
        let result = lock.withLock { () -> (Bool, CheckedContinuation<CaptureOpenInfo, any Error>?) in
            if state == .installed || state == .stopping { state = .stopping; return (true, nil) }
            guard state == .pending else { return (false, nil) }
            state = .abandoned; generation = nil
            let saved = continuation; continuation = nil
            return (false, saved)
        }
        result.1?.resume(throwing: CaptureOpenFailure(stage: "start", status: ECANCELED))
        return result.0
    }
    func didStop() { lock.withLock { generation = nil; state = .closed } }
}

/// AUHAL/legacy objects never cross the shared control queue. A late timed-out
/// open owns its own disposal; it cannot install into a newer user intent.
private final class AudioCaptureWorker: @unchecked Sendable {
    private let ticket = CaptureOpenTicket()
    private let queue = VPCAudioControlQueue()
    private var capture: VPCInputOnlyAudioCapture?
    private var engine: AVAudioEngine?
    private var engineObserver: (any NSObjectProtocol)?
    private var tapInstalled = false
    private var format: AVAudioFormat?
    private var deviceClass = "other"
    private var defaultClass = "other"
    private var backend = "auhal"
    private var logged = false

    func open(selection: InputDeviceResolution, sink: CaptureSink, preserving expected: CaptureOpenInfo?,
              onRoute: @escaping @Sendable (Int32) -> Void) async throws -> CaptureOpenInfo {
        let chosen = selection.chosen
        let deviceClass = chosen?.kind.captureLogClass ?? "other"
        let defaultClass = selection.systemDefault?.kind.captureLogClass ?? "other"
        let useEngine = UserDefaults.standard.string(forKey: "captureBackend") == "engine"
        let backend = useEngine ? "engine" : "auhal"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ticket.arm(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(1500)) { [ticket] in
                    let failure = CaptureOpenFailure(stage: "start", status: ETIMEDOUT)
                    if ticket.abandon(failure) {
                        RuntimeTrace.record("capture open backend=\(backend) device=\(deviceClass) default=\(defaultClass) stage=start status=\(failure.status) hwRate=0 ch=0 firstCallbackMs=-1 firstNonzeroMs=-1")
                    }
                }
                queue.async { [self] in
                    guard ticket.isPending else { return }
                    self.deviceClass = deviceClass; self.defaultClass = defaultClass; self.backend = backend
                    var stage = "new"
                    do {
                        let info: CaptureOpenInfo
                        let handler: AudioTapCallback = { [ticket] buffer, _ in
                            guard let generation = ticket.pcmGeneration() else { return }
                            ticket.notePCM(buffer)
                            // A fallback becomes usable only when PCM actually arrives.
                            InputDeviceRuntime.shared.confirmInputOpened(deviceID: ticket.sourceDeviceID(), selectionKey: chosen?.key)
                            sink.ingest(buffer, generation: generation)
                        }
                        if useEngine {
                            let legacy = AVAudioEngine(); engine = legacy
                            stage = "format"
                            let source = legacy.inputNode.inputFormat(forBus: 0)
                            guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0 else {
                                throw CaptureOpenFailure(stage: stage, status: kAudioUnitErr_FormatNotSupported)
                            }
                            format = source
                            info = .init(deviceID: chosen?.id ?? selection.systemDefault?.id ?? 0, format: source)
                            ticket.setResolvedDevice(info.deviceID)
                            try validate(info, expected: expected)
                            guard ticket.isPending else { dispose(finishing: nil); return }
                            prepareSink(sink, kind: chosen?.kind, preserving: expected != nil)
                            ticket.allowPCM(generation: sink.callbackGeneration)
                            tapInstalled = true
                            legacy.inputNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: handler)
                            engineObserver = NotificationCenter.default.addObserver(
                                forName: .AVAudioEngineConfigurationChange, object: legacy, queue: nil) { _ in
                                    onRoute(0)
                                }
                            stage = "start"; try legacy.start()
                        } else {
                            let unit = VPCInputOnlyAudioCapture(); capture = unit
                            let prepared = unit.prepare(uid: chosen?.captureUID ?? "", handler: handler)
                            guard prepared == noErr, let source = unit.format else {
                                throw CaptureOpenFailure(stage: unit.failureStage, status: prepared)
                            }
                            format = source; info = .init(deviceID: unit.resolvedDeviceID, format: source)
                            ticket.setResolvedDevice(info.deviceID)
                            try validate(info, expected: expected)
                            guard ticket.isPending else { dispose(finishing: nil); return }
                            unit.routeHandler = onRoute
                            prepareSink(sink, kind: chosen?.kind, preserving: expected != nil)
                            ticket.allowPCM(generation: sink.callbackGeneration)
                            let status = unit.start()
                            guard status == noErr else { throw CaptureOpenFailure(stage: unit.failureStage, status: status) }
                        }
                        if !ticket.complete(.success(info)) { dispose(finishing: nil) }
                    } catch {
                        let failure = (error as? CaptureOpenFailure) ?? .init(stage: stage, status: Int32(clamping: (error as NSError).code))
                        dispose(finishing: nil)
                        if ticket.complete(.failure(failure)) { recordOpen(failure: failure) }
                    }
                }
            }
        } onCancel: { [ticket] in
            _ = ticket.abandon(.init(stage: "start", status: ECANCELED))
        }
    }
    private func prepareSink(_ sink: CaptureSink, kind: InputDeviceClass?, preserving: Bool) {
        if preserving { sink.resumeCapture() }
        else {
            let bluetooth = kind == .bluetooth
            sink.beginCapture(configuration: .init(silenceMilliseconds: bluetooth ? 2000 : 500,
                noCallbackMilliseconds: bluetooth ? 2500 : 300, stalledMilliseconds: bluetooth ? 2500 : 500))
        }
    }
    func healthFailure(bluetooth: Bool) -> String? { ticket.healthFailure(bluetooth: bluetooth) }
    private func validate(_ info: CaptureOpenInfo, expected: CaptureOpenInfo?) throws {
        guard let expected else { return }
        guard InputRouteResumePolicy.canResume(oldDevice: expected.deviceID, newDevice: info.deviceID,
            oldRate: expected.format.sampleRate, newRate: info.format.sampleRate,
            oldChannels: expected.format.channelCount, newChannels: info.format.channelCount,
            oldLayout: expected.format.commonFormat.rawValue, newLayout: info.format.commonFormat.rawValue,
            oldInterleaved: expected.format.isInterleaved, newInterleaved: info.format.isInterleaved) else {
            throw CaptureOpenFailure(stage: "format", status: kAudioUnitErr_FormatNotSupported)
        }
    }
    func close(finishing: (@Sendable () -> Void)? = nil, failure: CaptureOpenFailure? = nil) async {
        guard ticket.beginStop() else {
            // An abandoned/uninstalled open can still be stuck in HAL. Seal now;
            // its queued job will dispose itself whenever HAL eventually returns.
            finishing?()
            return
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                dispose(finishing: finishing)
                recordOpen(failure: failure)
                ticket.didStop()
                continuation.resume()
            }
        }
    }
    func abandonAndDispose(finishing: @escaping @Sendable () -> Void) {
        if !ticket.beginStop() { finishing(); return }
        queue.async { [self] in
            dispose(finishing: finishing); recordOpen(failure: nil); ticket.didStop()
        }
    }
    private func dispose(finishing: (@Sendable () -> Void)?) {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
        if let capture { capture.stop(finishing: finishing) }
        else {
            engine?.stop()
            if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
            finishing?()
        }
        engine = nil
    }
    private func recordOpen(failure: CaptureOpenFailure?) {
        guard !logged else { return }; logged = true
        if let capture {
            var line = capture.openDiagnostic(deviceClass: deviceClass, defaultClass: defaultClass)
            if let failure {
                // A client-side format boundary or callback deadline is also finite.
                for stage in ["new", "enableIO", "setDevice", "format", "init", "start"] {
                    line = line.replacingOccurrences(of: "stage=\(stage) status=0",
                        with: "stage=\(failure.stage) status=\(failure.status)")
                }
            }
            RuntimeTrace.record(line)
        } else {
            let times = ticket.times()
            RuntimeTrace.record("capture open backend=engine device=\(deviceClass) default=\(defaultClass) stage=\(failure?.stage ?? "start") status=\(failure?.status ?? 0) hwRate=\(Int(format?.sampleRate ?? 0)) ch=\(format?.channelCount ?? 0) firstCallbackMs=\(times.0) firstNonzeroMs=\(times.1)")
        }
        capture = nil
    }
}

@MainActor
final class LiveAudioPipeline {
    let input: BoundedPCMStream?
    let captured: CapturedPCMStore
    var onCaptureFailure: (@Sendable (String) -> Void)?
    var onDurationLimitReached: (@Sendable () -> Void)?
    private let sink: CaptureSink
    private var worker: AudioCaptureWorker?
    private var stopTask: Task<Void, Never>?
    private var captureCloseTask: Task<Void, Never>?
    private var recovering = false
    private var ended = false
    private var announcedCapture = false
    private var inventoryObserver: (any NSObjectProtocol)?
    private var silenceCheckTask: Task<Void, Never>?
    private var routeReopenTask: Task<Void, Never>?
    private var routeGeneration: UInt64 = 0
    private var routeReopens = 0
    private var captureStartedAt: UInt64 = 0
    private var captureInfo: CaptureOpenInfo?
    private var captureKind: InputDeviceClass?
    private var captureFollowsDefault = false
    private var deviceFields = "deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown"
    private(set) var ignoredConfigurations = 0
    var smokeDeviceID: UInt32 { captureInfo?.deviceID ?? 0 }
    var smokeNumbers: (callbacks: Int, nonzero: Int, reopens: Int, ignored: Int) {
        let counts = sink.diagnostics.counts()
        return (counts.callbacks, counts.nonzero, routeReopens, ignoredConfigurations)
    }

    init(capacity: Int = 32, appleEnabled: Bool,
         captureByteLimit: Int = CapturedPCMStore.byteLimit,
         captureDurationSeconds: Double = CapturedPCMStore.durationSeconds,
         gracefulDurationLimit: Bool = false, diagnosticsOnly: Bool = false) {
        let stream = appleEnabled ? BoundedPCMStream(capacity: capacity) : nil
        input = stream
        captured = CapturedPCMStore(byteLimit: captureByteLimit, durationSeconds: captureDurationSeconds)
        sink = CaptureSink(store: captured, input: stream, gracefulDurationLimit: gracefulDurationLimit, diagnosticsOnly: diagnosticsOnly)
    }
    func makeAudioCallback() -> AudioTapCallback { AudioTapCallbackFactory.make(sink: sink) }
    func prepareForCallbackTesting(silenceGate: Bool = false, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        installCaptureFailureHandler()
        if silenceGate { sink.beginCapture(now: now) }
    }
    private func installCaptureFailureHandler() {
        sink.setFailureHandler { [weak self] code in
            Task { @MainActor [weak self] in await self?.failCapture(code: code) }
        }
    }
    func start(streamingToApple: Bool) async throws {
        guard !ended, worker == nil else { throw TrialCoreError.invalid("PIPELINE_ALREADY_ENDED") }
        installCaptureFailureHandler()
        if !streamingToApple { sink.disableAppleStreaming() }
        sink.setSilenceHandler { [weak self] code in
            Task { @MainActor [weak self] in await self?.recoverSilentInput(code: code) }
        }
        do {
            try await openCapture()
        } catch {
            guard !ended, !Task.isCancelled else { throw error }
            await detachCapture()
            guard InputDeviceRuntime.shared.fallback(reason: "startFailed", atMs: 0) != nil else {
                InputDeviceRuntime.shared.reportOpenFailure()
                await stop(); throw TrialCoreError.invalid("INPUT_DEVICE_SELECTION_FAILED")
            }
            do { try await openCapture() }
            catch {
                guard !ended, !Task.isCancelled else { throw error }
                InputDeviceRuntime.shared.reportOpenFailure()
                await stop(); throw TrialCoreError.invalid("INPUT_DEVICE_SELECTION_FAILED")
            }
        }
        guard !ended else { throw CancellationError() }
        silenceCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, !self.ended else { return }
                self.sink.checkSilence()
                if self.sink.hasAcceptedAudio, let reason = self.worker?.healthFailure(bluetooth: self.captureKind == .bluetooth) {
                    await self.recoverSilentInput(code: "MICROPHONE_NO_CALLBACKS", healthReason: reason)
                }
            }
        }
        if inventoryObserver == nil {
            inventoryObserver = NotificationCenter.default.addObserver(forName: InputDeviceInventory.changed, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.inventoryChanged() }
            }
        }
    }
    private func openCapture(preserving expected: CaptureOpenInfo? = nil) async throws {
        let selection = InputDeviceRuntime.shared.selection()
        guard selection.reason != "failedUnavailable" else {
            throw CaptureOpenFailure(stage: "setDevice", status: kAudioUnitErr_InvalidPropertyValue)
        }
        let candidate = AudioCaptureWorker()
        worker = candidate
        routeGeneration &+= 1
        let generation = routeGeneration
        let info = try await candidate.open(selection: selection, sink: sink, preserving: expected) { [weak self] status in
            Task { @MainActor [weak self] in self?.routeChanged(generation: generation, status: status) }
        }
        guard !ended, generation == routeGeneration, worker === candidate else {
            await candidate.close(finishing: { [sink] in sink.finish() })
            throw CancellationError()
        }
        captureInfo = info
        captureKind = selection.chosen?.kind
        captureFollowsDefault = selection.policy != .pinned && selection.chosen?.id == selection.systemDefault?.id
        deviceFields = InputDeviceInventory.diagnosticFields(for: info.deviceID)
        captureStartedAt = DispatchTime.now().uptimeNanoseconds
        RuntimeTrace.record(CaptureDiagnosticLog.start(deviceFields: deviceFields, format: info.format))
        announceCapture(true)
    }
    private func announceCapture(_ active: Bool) {
        guard active != announcedCapture else { return }; announcedCapture = active
        if active { CaptureLevelBus.shared.captureBegan() } else { CaptureLevelBus.shared.captureEnded() }
    }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        ended = true
        silenceCheckTask?.cancel(); silenceCheckTask = nil
        routeReopenTask?.cancel(); routeReopenTask = nil
        routeGeneration &+= 1
        if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver); self.inventoryObserver = nil }
        announceCapture(false)
        let capture = worker; worker = nil
        let closing = captureCloseTask
        let sink = sink, fields = deviceFields
        let task = Task {
            if let closing { await closing.value }
            if let capture { await capture.close(finishing: { sink.finish() }) }
            else { sink.finish() }
            RuntimeTrace.record(CaptureDiagnosticLog.end(deviceFields: fields, diagnostics: sink.diagnostics))
        }
        stopTask = task
        await task.value
    }
    func cancel() async { await stop() }
    func disableAppleStreaming() { sink.disableAppleStreaming() }
    private func failCapture(code: String) async {
        let duration = code == "CAPTURE_DURATION_REACHED" && captured.didReachDurationLimit
        await stop()
        if duration { onDurationLimitReached?() } else { onCaptureFailure?(code) }
    }
    private func detachCapture(failure: CaptureOpenFailure? = nil) async {
        if let captureCloseTask { await captureCloseTask.value }
        let detached = worker; worker = nil
        guard let detached else { return }
        let task = Task { await detached.close(failure: failure) }
        captureCloseTask = task
        await task.value
        captureCloseTask = nil
    }
    private func recoverSilentInput(code: String, healthReason: String? = nil) async {
        guard !ended, !recovering, routeReopenTask == nil else { return }
        let hadAudio = sink.hasAcceptedAudio
        guard !hadAudio || healthReason != nil else { return }
        let old = captureInfo
        recovering = true
        defer { recovering = false }
        let decision = sink.silenceDecision
        let reason = healthReason ?? (decision == .noCallbacks || decision == .stalled ? "noCallbacks" : "allZero")
        let fallback = InputDeviceRuntime.shared.fallback(reason: reason,
            atMs: (DispatchTime.now().uptimeNanoseconds - captureStartedAt) / 1_000_000)
        await detachCapture(failure: reason == "noCallbacks" ? .init(stage: "start", status: ETIMEDOUT) : nil)
        guard !ended else { return }
        guard fallback != nil else {
            if hadAudio { await preserveCapturedAudio(); return }
            InputDeviceRuntime.shared.reportOpenFailure()
            sink.terminate(.invalid(reason == "noCallbacks" ? "INPUT_DEVICE_SELECTION_FAILED" : code))
            return
        }
        do { try await openCapture(preserving: hadAudio ? old : nil) }
        catch {
            guard !ended else { return }
            if hadAudio { await preserveCapturedAudio(); return }
            InputDeviceRuntime.shared.reportOpenFailure()
            sink.terminate(.invalid("INPUT_DEVICE_SELECTION_FAILED"))
        }
    }
    private func inventoryChanged() {
        guard !ended, let info = captureInfo else { return }
        let available = InputDeviceInventory.hasInputStreams(info.deviceID)
        let rate = InputDeviceInventory.nominalRate(info.deviceID)
        let rateChanged = rate > 0 && abs(rate - info.format.sampleRate) >= 1
        let defaultMoved = captureKind != .builtin && captureFollowsDefault &&
            InputDeviceInventory.defaultInputID() != info.deviceID
        guard !available || rateChanged || defaultMoved else { ignoredConfigurations += 1; return }
        routeChanged(generation: routeGeneration, status: 0)
    }
    private func routeChanged(generation: UInt64, status: Int32) {
        guard !ended, !recovering, generation == routeGeneration, routeReopenTask == nil else { return }
        let old = captureInfo, hadAudio = sink.hasAcceptedAudio
        if status != 0 && hadAudio {
            routeReopenTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.preserveCapturedAudio()
            }
            return
        }
        guard routeReopens < 2 else {
            routeReopenTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if hadAudio { await self.preserveCapturedAudio() }
                else { self.sink.terminate(.invalid("AUDIO_ROUTE_REOPEN_FAILED")) }
            }
            return
        }
        routeReopens += 1
        RuntimeTrace.record(CaptureDiagnosticLog.reopen(attempt: routeReopens))
        routeReopenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.detachCapture(failure: status == 0 ? nil : .init(stage: "start", status: status))
            guard !self.ended else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            InputDeviceRuntime.shared.beginIntent(resetFallback: false)
            do {
                try await self.openCapture(preserving: hadAudio ? old : nil)
                self.routeReopenTask = nil
            } catch {
                self.routeReopenTask = nil
                guard !self.ended else { return }
                if hadAudio { await self.preserveCapturedAudio() }
                else { await self.recoverSilentInput(code: "AUDIO_ROUTE_REOPEN_FAILED") }
            }
        }
    }
    private func preserveCapturedAudio() async {
        await stop()
        RuntimeTrace.record("capture_route phase=sealed reason=routeChanged")
        NotificationCenter.default.post(name: InputDeviceRuntime.notice, object: nil,
            userInfo: ["message": "麦克风切换了，后面的话没录到"])
    }
    deinit {
        silenceCheckTask?.cancel(); routeReopenTask?.cancel()
        if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver) }
        if announcedCapture { CaptureLevelBus.shared.captureEnded() }
        let sink = sink
        if let worker { worker.abandonAndDispose(finishing: { sink.finish() }) }
        else { sink.finish() }
    }
}

struct PCM16MemoryBridge: Sendable {
    let data: Data
    let durationSeconds: Double

    static func make(from buffers: [OwnedPCMBuffer]) throws -> PCM16MemoryBridge {
        guard let first = buffers.first, first.buffer.frameLength > 0 else {
            throw TrialCoreError.invalid("NO_AUDIO_CAPTURED")
        }
        let source = first.buffer.format
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = PersistentPCMConverter(source: source, target: target) else {
            throw TrialCoreError.invalid("AUDIO_CONVERTER_UNAVAILABLE")
        }
        var data = Data()
        var frames = 0
        func append(_ output: [OwnedPCMBuffer]) throws {
            for owned in output {
                let list = UnsafeMutableAudioBufferListPointer(owned.buffer.mutableAudioBufferList)
                for buffer in list {
                    if let bytes = buffer.mData {
                        let chunkBytes = Int(buffer.mDataByteSize)
                        guard chunkBytes >= 0, chunkBytes <= 1_920_000 - data.count else {
                            throw TrialCoreError.invalid("PCM_MEMORY_LIMIT_EXCEEDED")
                        }
                        data.append(Data(bytes: bytes, count: chunkBytes))
                    }
                }
                frames += Int(owned.buffer.frameLength)
            }
        }
        for buffer in buffers { try append(try converter.convert(buffer)) }
        try append(try converter.flush())
        return PCM16MemoryBridge(data: data, durationSeconds: Double(frames) / 16_000)
    }
}
