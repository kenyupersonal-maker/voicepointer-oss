// T8 2026-10-02: Bounded, opt-in memory outlet from the existing HUD meter tap. No engine or file I/O.
@preconcurrency import AVFoundation
import Foundation

public final class DoubaoLearningAudio: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var buffers: [OwnedPCMBuffer]
    private let createdAt: UInt64
    internal init(_ buffers: [OwnedPCMBuffer], createdAt: UInt64? = nil) {
        self.buffers = buffers
        let duration = buffers.reduce(0.0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
        let current = DispatchTime.now().uptimeNanoseconds
        let retained = UInt64(min(max(duration, 0), 300) * 1_000_000_000)
        self.createdAt = createdAt ?? (current > retained ? current - retained : 0)
    }
    public static func == (lhs: DoubaoLearningAudio, rhs: DoubaoLearningAudio) -> Bool { lhs === rhs }
    public var ageSeconds: Double { Double(DispatchTime.now().uptimeNanoseconds - createdAt) / 1_000_000_000 }
    internal func fork() -> DoubaoLearningAudio { lock.withLock { DoubaoLearningAudio(buffers, createdAt: createdAt) } }
    internal func takeBuffers() -> [OwnedPCMBuffer] { lock.withLock { let value = buffers; buffers = []; return value } }
    public func clear() { lock.withLock { buffers = [] } }
    public var retainedBufferCount: Int { lock.withLock { buffers.count } }
    public var durationSeconds: Double { lock.withLock {
        buffers.reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
    } }
}

public enum DoubaoLearningAudioResult: Sendable {
    case audio(DoubaoLearningAudio), missing, silent, clipped
}

public protocol DoubaoLearningAudioProviding: Sendable {
    func arm()
    func take() -> DoubaoLearningAudioResult
    func clear()
}

public final class DoubaoLearningAudioRing: DoubaoLearningAudioProviding, @unchecked Sendable {
    public static let shared = DoubaoLearningAudioRing()
    private let lock = NSLock()
    private let byteLimit: Int
    private let durationLimit: Double
    private var slots: [OwnedPCMBuffer?]
    private var head = 0, count = 0, bytes = 0
    private var seconds = 0.0
    private var armed = false, clipped = false
    private var gate = MicrophoneSilenceGate()
    private var rate: Double?, channels: AVAudioChannelCount?
    public init(byteLimit: Int = 256 * 1024 * 1024, durationLimit: Double = 300, bufferLimit: Int = 4096) {
        self.byteLimit = min(max(1, byteLimit), 256 * 1024 * 1024)
        self.durationLimit = min(max(0.01, durationLimit), 300)
        slots = Array(repeating: nil, count: min(max(1, bufferLimit), 4096))
    }
    public var isArmed: Bool { lock.withLock { armed } }
    public var retainedBufferCount: Int { lock.withLock { count } }
    public func arm() { lock.withLock { reset(); gate = MicrophoneSilenceGate(); armed = true } }
    public func clear() { lock.withLock { reset() } }
    private func reset() {
        for index in slots.indices { slots[index] = nil }
        head = 0; count = 0; bytes = 0; seconds = 0; armed = false; clipped = false; rate = nil; channels = nil
    }
    private func bufferBytes(_ buffer: OwnedPCMBuffer) -> Int {
        UnsafeMutableAudioBufferListPointer(buffer.buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
    }
    /// Called synchronously by the existing tap, only after its isArmed guard; copies borrowed memory once.
    public func appendMeterBuffer(_ buffer: AVAudioPCMBuffer, rawPeak: Float) {
        lock.withLock {
            guard armed else { return }
            _ = gate.observe(peak: rawPeak)
            guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                  rate == nil || (rate == buffer.format.sampleRate && channels == buffer.format.channelCount),
                  let owned = try? OwnedPCMBuffer(copying: buffer) else { clipped = true; return }
            rate = buffer.format.sampleRate; channels = buffer.format.channelCount
            let size = bufferBytes(owned), duration = Double(buffer.frameLength) / buffer.format.sampleRate
            guard size <= byteLimit, duration <= durationLimit else { clipped = true; return }
            while count > 0 && (count == slots.count || bytes + size > byteLimit || seconds + duration > durationLimit) {
                if let old = slots[head] {
                    bytes -= bufferBytes(old); seconds -= Double(old.buffer.frameLength) / old.buffer.format.sampleRate
                }
                slots[head] = nil; head = (head + 1) % slots.count; count -= 1; clipped = true
            }
            slots[(head + count) % slots.count] = owned; count += 1; bytes += size; seconds += duration
        }
    }
    public func take() -> DoubaoLearningAudioResult {
        lock.withLock {
            defer { reset() }
            guard armed, count > 0 else { return .missing }
            guard !clipped else { return .clipped }
            guard !gate.decision(final: true).blocksRecognition else { return .silent }
            let buffers = (0..<count).compactMap { slots[(head + $0) % slots.count] }
            return .audio(DoubaoLearningAudio(buffers))
        }
    }
}
