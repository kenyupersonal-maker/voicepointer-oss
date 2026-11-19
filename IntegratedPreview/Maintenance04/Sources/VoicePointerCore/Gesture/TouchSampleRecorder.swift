import Foundation
import AppKit
import Darwin
import CMultitouchSupport

public enum TouchSampleDecision: Int, Codable, Sendable { case touchCount, landingSkew, freshWindow, movement, frameExpired, density, passed }
public enum TouchSampleLabel: String, Codable, CaseIterable, Sendable { case none, single, real }
public struct TouchSamplePoint: Codable, Equatable, Sendable {
    public var stage: Int
    public var x, y, major, minor, size, density: Float
    public var edge: Bool? = nil
    public init(stage: Int, x: Float, y: Float, major: Float, minor: Float, size: Float, density: Float, edge: Bool? = nil) {
        self.stage = stage; self.x = x; self.y = y; self.major = major; self.minor = minor; self.size = size; self.density = density
        self.edge = edge
    }
}
public struct TouchSurfaceSnapshot: Equatable, Sendable {
    public var deviceToken: UInt
    public var points: [TouchSamplePoint]
    public var frameAgeSeconds, newestTouchAgeSeconds, oldestTouchAgeSeconds: Double
    public var maximumMovement: Float
    public init(deviceToken: UInt, points: [TouchSamplePoint], frameAgeSeconds: Double,
                newestTouchAgeSeconds: Double, oldestTouchAgeSeconds: Double, maximumMovement: Float) {
        self.deviceToken = deviceToken; self.points = Array(points.prefix(6)); self.frameAgeSeconds = frameAgeSeconds
        self.newestTouchAgeSeconds = newestTouchAgeSeconds; self.oldestTouchAgeSeconds = oldestTouchAgeSeconds
        self.maximumMovement = maximumMovement
    }
    public var minDensity: Float { points.filter { $0.stage == 4 && $0.edge != true }.map(\.density).min() ?? 0 }
}
public struct TouchSampleLatestDecision: Equatable, Sendable {
    public var reason: TouchSampleDecision
    public var minDensity: Float
    public var threshold: Float
    public var skewSeconds, oldestAgeSeconds: Double?
    public var retriedWithoutLift: Bool?
    public init(reason: TouchSampleDecision, minDensity: Float, threshold: Float = 1,
                skewSeconds: Double? = nil, oldestAgeSeconds: Double? = nil, retriedWithoutLift: Bool? = nil) {
        self.reason = reason; self.minDensity = minDensity; self.threshold = threshold
        self.skewSeconds = skewSeconds; self.oldestAgeSeconds = oldestAgeSeconds
        self.retriedWithoutLift = retriedWithoutLift
    }
}
public struct TouchSampleDecisionFrame: Equatable, Sendable {
    public let decision: TouchSampleLatestDecision
    public let snapshot: TouchSurfaceSnapshot
    public init(decision: TouchSampleLatestDecision, snapshot: TouchSurfaceSnapshot) {
        self.decision = decision; self.snapshot = snapshot
    }
}
public struct TouchSample: Codable, Equatable, Sendable {
    public var t: Double
    public var b: String
    public var dec: TouchSampleDecision
    public var n, hover: Int
    public var points: [TouchSamplePoint]
    public var holdMS: Double
    public var threshold: Float
    public var skewLimitMS, freshLimitMS: Int
    public var movementLimit: Float
    public var frameAgeMS, newestAgeMS, oldestAgeMS: Double
    public var movement: Float
    public var label: TouchSampleLabel
    // Optional so legacy rows stay decodable without inventing gate measurements.
    public var gateMinDensity: Float? = nil
    public var skewMS: Double? = nil
    public var retriedWithoutLift: Bool? = nil
    public var edgeCount: Int? = nil
    public var minDensity: Float { points.filter { $0.stage == 4 && $0.edge != true }.map(\.density).min() ?? 0 }
    public func wouldTrigger(configuration c: GestureConfiguration) -> Bool {
        let active = points.filter { $0.stage == 4 && !MagicMouseChordRule.isEdge($0, configuration: c) }
        guard !active.isEmpty, active.count == c.magicMouseFingerCount, frameAgeMS >= 0, frameAgeMS <= 150,
              newestAgeMS >= 0, oldestAgeMS >= 0,
              (skewMS ?? (oldestAgeMS - newestAgeMS)) <= Double(c.magicMouseMaxLandingSkewMilliseconds) + 0.0001,
              oldestAgeMS <= Double(c.magicMouseFreshChordWindowMilliseconds),
              movement <= c.maximumTouchMovement else { return false }
        let need = MagicMouseChordRule.requiredDensity(configuration: c, skewMilliseconds: skewMS ?? oldestAgeMS - newestAgeMS)
        let removed = points.contains { $0.stage == 4 && MagicMouseChordRule.isEdge($0, configuration: c) }
        let density = removed ? (active.map(\.density).min() ?? 0) : gateMinDensity ?? active.map(\.density).min() ?? 0
        return need.isFinite && (need <= 0 || density >= need)
    }
}
public struct TouchSampleComparison: Equatable, Sendable {
    public var label: TouchSampleLabel
    public var count: Int
    public var triggered: Int
    public var ratio: Double { count == 0 ? 0 : Double(triggered) / Double(count) }
}
public enum TouchSampleStorageState: Int, Sendable { case idle, busy, failed }
/// Event callbacks only enqueue bounded work. All file operations and pairing happen on queue.
public final class TouchSampleRecorder: @unchecked Sendable {
    public static let shared = TouchSampleRecorder(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.kenyu.voicepointer.mac"))
    public static let maximumFileBytes = 2_000_000
    private let queue = DispatchQueue(label: "com.kenyu.voicepointer.touch-samples", qos: .utility)
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private let directory: URL
    private let rotateBytes: Int
    private let trash: @Sendable (URL) throws -> Void
    private var enabled = true
    private var marking: TouchSampleLabel = .none
    private var suspended = false
    private var generation: UInt64 = 0
    private var latest: TouchSampleLatestDecision?
    private var latestSnapshot: TouchSurfaceSnapshot?
    private var state: TouchSampleStorageState = .idle
    private var samples: [TouchSample] = []
    private var loaded = false
    private var pending: [String: (TouchSample, Double)] = [:]
    private var dropped: Int = 0
    public init(directory: URL, maximumQueuedOperations: Int = 256, rotateBytes: Int = 2_000_000,
                trash: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory; self.rotateBytes = rotateBytes; slots = DispatchSemaphore(value: max(1, maximumQueuedOperations))
        self.trash = trash
    }
    public var fileURL: URL { directory.appendingPathComponent("touch-samples.jsonl") }
    public var rotatedURL: URL { directory.appendingPathComponent("touch-samples.jsonl.1") }
    public var recordingEnabled: Bool { lock.withLock { enabled } }
    public var label: TouchSampleLabel { get { lock.withLock { marking } } set { lock.withLock { marking = newValue } } }
    public var latestDecision: TouchSampleLatestDecision? { lock.withLock { latest } }
    public var latestDecisionSnapshot: TouchSurfaceSnapshot? { lock.withLock { latestSnapshot } }
    public var storageState: TouchSampleStorageState { lock.withLock { state } }
    public var droppedCount: Int { lock.withLock { dropped } }
    public var recentSamples: [TouchSample] { lock.withLock { samples } }
    public func refreshRecentSamples() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !lock.withLock({ suspended }) else { continuation.resume(); return }
                loadIfNeeded(); continuation.resume()
            }
        }
    }
    public func configure(_ c: GestureConfiguration) {
        VPSetMagicMouseEdgeFilter(c.magicMouseEdgeMargin, c.magicMouseEdgeMaxMinor)
        let disabled = lock.withLock { () -> Bool in
            let changed = enabled && !c.touchSampleRecordingEnabled
            enabled = c.touchSampleRecordingEnabled
            if changed { generation &+= 1 }
            return changed
        }
        if disabled { queue.async { [self] in pending.removeAll() } }
    }
    public func updateDecision(_ d: TouchSampleLatestDecision, snapshot: TouchSurfaceSnapshot?) {
        lock.withLock { latest = d; latestSnapshot = snapshot }
    }
    public static func compare(_ samples: [TouchSample], configuration: GestureConfiguration) -> [TouchSampleComparison] {
        let recent = samples.filter { $0.label != .none }.suffix(500)
        return [TouchSampleLabel.single, .real].map { label in
            let values = recent.filter { $0.label == label }
            return .init(label: label, count: values.count, triggered: values.filter { $0.wouldTrigger(configuration: configuration) }.count)
        }
    }
    private func enqueue(_ action: @escaping @Sendable () -> Void) {
        guard slots.wait(timeout: .now()) == .success else { lock.withLock { dropped += 1 }; return }
        queue.async { [self] in action(); slots.signal() }
    }
    public func recordDown(button: PhysicalMouseButton, frame: TouchSampleDecisionFrame, configuration: GestureConfiguration,
                           wallTime: Double = Date().timeIntervalSince1970, monotonicTime: Double = ProcessInfo.processInfo.systemUptime) {
        recordDown(button: button, snapshot: frame.snapshot, configuration: configuration,
                   decision: frame.decision, wallTime: wallTime, monotonicTime: monotonicTime)
    }
    public func recordDown(button: PhysicalMouseButton, snapshot: TouchSurfaceSnapshot?, configuration c: GestureConfiguration,
                           decision: TouchSampleLatestDecision? = nil,
                           wallTime: Double = Date().timeIntervalSince1970, monotonicTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard let snapshot else { return }
        guard snapshot.points.allSatisfy({ p in
            [p.x, p.y, p.major, p.minor, p.size, p.density].allSatisfy(\.isFinite) &&
            (0...31).contains(p.stage) && (0...1).contains(p.x) && (0...1).contains(p.y)
        }), [snapshot.frameAgeSeconds * 1000, snapshot.newestTouchAgeSeconds * 1000,
             snapshot.oldestTouchAgeSeconds * 1000, wallTime, monotonicTime].allSatisfy(\.isFinite),
        snapshot.maximumMovement.isFinite, c.magicMouseMinDensity.isFinite, c.maximumTouchMovement.isFinite else { return }
        if let decision {
            guard decision.minDensity.isFinite, decision.threshold.isFinite,
                  decision.skewSeconds.map({ ($0 * 1000).isFinite }) ?? true,
                  decision.oldestAgeSeconds.map({ ($0 * 1000).isFinite }) ?? true else { return }
        }
        let buttonCode = button == .left ? "L" : "R"
        let values = lock.withLock { (enabled && !suspended, generation, marking, latest) }
        guard values.0 else { return }
        let points = snapshot.points.map { point -> TouchSamplePoint in
            var point = point; point.edge = MagicMouseChordRule.isEdge(point, configuration: c); return point
        }
        let active = points.filter { $0.stage == 4 && $0.edge != true }
        var sample = TouchSample(t: wallTime, b: buttonCode, dec: decision?.reason ?? values.3?.reason ?? .touchCount,
            n: active.count, hover: points.filter { $0.stage != 4 }.count,
            points: points,
            holdMS: -1, threshold: decision?.threshold ?? c.magicMouseMinDensity, skewLimitMS: c.magicMouseMaxLandingSkewMilliseconds,
            freshLimitMS: c.magicMouseFreshChordWindowMilliseconds, movementLimit: c.maximumTouchMovement,
            frameAgeMS: snapshot.frameAgeSeconds * 1000, newestAgeMS: snapshot.newestTouchAgeSeconds * 1000,
            oldestAgeMS: (decision?.oldestAgeSeconds ?? snapshot.oldestTouchAgeSeconds) * 1000,
            movement: snapshot.maximumMovement, label: values.2)
        sample.gateMinDensity = decision?.minDensity
        sample.edgeCount = points.filter { $0.stage == 4 && $0.edge == true }.count
        sample.skewMS = decision?.skewSeconds.map { $0 * 1000 }
        sample.retriedWithoutLift = decision?.retriedWithoutLift
        let frozenSample = sample
        enqueue { [self] in
            guard lock.withLock({ !suspended && generation == values.1 }) else { return }
            loadIfNeeded()
            append(frozenSample)
            pending[buttonCode] = (frozenSample, monotonicTime)
        }
    }
    public func recordUp(button: PhysicalMouseButton, monotonicTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard monotonicTime.isFinite else { return }
        let code = button == .left ? "L" : "R"
        let gen = lock.withLock { generation }
        enqueue { [self] in
            guard lock.withLock({ !suspended && generation == gen }), var pair = pending.removeValue(forKey: code) else { return }
            let duration = max(0, (monotonicTime - pair.1) * 1000)
            guard duration.isFinite else { return }
            pair.0.holdMS = duration
            completeDuration(pair.0)
        }
    }
    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        guard safePaths() else { lock.withLock { state = .failed }; return }
        var records: [TouchSample] = []
        for url in [rotatedURL, fileURL] {
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  size.intValue <= rotateBytes, let data = try? Data(contentsOf: url), data.count <= rotateBytes else { continue }
            for line in data.split(separator: 10) {
                if let sample = try? JSONDecoder().decode(TouchSample.self, from: Data(line)), sample.label != .none { records.append(sample) }
            }
        }
        lock.withLock { samples = Array(records.suffix(500)) }
    }
    private func append(_ sample: TouchSample) {
        guard lock.withLock({ enabled && !suspended }) else { return }
        guard safePaths() else { lock.withLock { state = .failed }; return }
        guard let encoded = try? JSONEncoder().encode(sample), encoded.count + 1 <= rotateBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var line = encoded; line.append(10)
            let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
            guard size <= rotateBytes else { throw CocoaError(.fileReadTooLarge) }
            if size + line.count + 64 > rotateBytes {
                if FileManager.default.fileExists(atPath: rotatedURL.path) { try trash(rotatedURL) }
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.moveItem(at: fileURL, to: rotatedURL) }
            }
            let descriptor = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= rotateBytes - line.count else { throw CocoaError(.fileWriteOutOfSpace) }
            try Self.writeAll(line, descriptor: descriptor)
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            lock.withLock {
                if sample.label != .none { samples.append(sample); samples = Array(samples.suffix(500)) }
                state = .idle
            }
        } catch { lock.withLock { state = .failed } }
    }
    /// A down is immediately durable; up replaces that row, never adds a second sample.
    private func completeDuration(_ sample: TouchSample) {
        guard lock.withLock({ enabled && !suspended }), safePaths() else { return }
        do {
            for url in [fileURL, rotatedURL] {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                      size.intValue <= rotateBytes else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url)
                guard data.count <= rotateBytes else { throw CocoaError(.fileReadTooLarge) }
                var lines: [Data] = data.split(separator: UInt8(10)).map { Data($0) }
                guard let index = lines.lastIndex(where: {
                    guard let value = try? JSONDecoder().decode(TouchSample.self, from: $0) else { return false }
                    return value.t == sample.t && value.b == sample.b
                }) else { continue }
                lines[index] = try JSONEncoder().encode(sample)
                var updated = Data()
                for line in lines { updated.append(line); updated.append(10) }
                // Reserve bounded headroom for the eventual duration when accepting down.
                guard updated.count <= rotateBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try replaceDuration(updated, at: url)
                lock.withLock {
                    if let i = samples.lastIndex(where: { $0.t == sample.t && $0.b == sample.b }) { samples[i] = sample }
                }
                return
            }
        } catch { lock.withLock { state = .failed } }
    }
    public func beginDataRemoval() async {
        lock.withLock { suspended = true; generation &+= 1; state = .busy }
        await withCheckedContinuation { continuation in queue.async { [self] in pending.removeAll(); continuation.resume() } }
    }
    public func endDataRemoval(permanently: Bool = false) { lock.withLock { suspended = permanently; state = .idle } }
    public func clear() async -> TouchSampleStorageState {
        await beginDataRemoval()
        let result: TouchSampleStorageState = await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard safePaths() else { throw CocoaError(.fileReadNoPermission) }
                    for url in [fileURL, rotatedURL] where FileManager.default.fileExists(atPath: url.path) {
                        try trash(url)
                    }
                    lock.withLock { samples.removeAll(); state = .idle }
                    continuation.resume(returning: .idle)
                } catch { lock.withLock { state = .failed }; continuation.resume(returning: .failed) }
            }
        }
        lock.withLock { suspended = false }
        return result
    }
    @_spi(Testing) public func flushForTesting() { queue.sync {} }
    @_spi(Testing) public func blockQueueForTesting(_ action: @escaping @Sendable () -> Void) { enqueue(action) }
    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += amount
            }
        }
    }
    /// Foundation's generic atomic temporary location is unavailable inside the offline profile.
    /// Keep staging, fsync and promotion in this recorder's own directory; failed stages go to Trash.
    private func replaceDuration(_ data: Data, at target: URL) throws {
        let stage = directory.appendingPathComponent(".touch-samples-" + UUID().uuidString + ".stage")
        let descriptor = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var promoted = false
        defer {
            _ = Darwin.close(descriptor)
            if !promoted { try? trash(stage) }
        }
        try Self.writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0, safePaths(), Darwin.rename(stage.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        promoted = true
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if parent >= 0 { _ = fsync(parent); _ = Darwin.close(parent) }
    }
    private func safePaths() -> Bool {
        guard !directory.pathComponents.contains("..") else { return false }
        var ancestor = directory.standardizedFileURL
        while ancestor.path != "/" {
            do {
                guard (try FileManager.default.attributesOfItem(atPath: ancestor.path)[.type] as? FileAttributeType) == .typeDirectory else { return false }
            } catch {
                guard (error as NSError).domain == NSCocoaErrorDomain,
                      [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) else { return false }
            }
            ancestor.deleteLastPathComponent()
        }
        return [fileURL, rotatedURL].allSatisfy {
            do {
                return (try FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeRegular
            } catch {
                return (error as NSError).domain == NSCocoaErrorDomain &&
                    [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code)
            }
        }
    }
}
