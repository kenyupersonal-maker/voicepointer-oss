import Foundation
import Darwin

/// File-operation seam for deterministic fault injection (Testing SPI only).
/// Each case wraps one unit of disk work inside the writer queue; production
/// never injects anything.
@_spi(Testing)
public enum TraceFault: Hashable, Sendable {
    /// Creating/opening the session file: directory creation, file creation,
    /// handle open, seek-to-end, and the first header write all count as one
    /// open attempt.
    case openSession
    /// Writing one accepted event line. Header and summary writes do not
    /// consume this budget.
    case write
    /// The capacity-rotation step as a whole.
    case rotate
}

private enum FaultInjected: Error { case injected }

/// Bounded, serialized local diagnostics. Messages must not contain user text.
///
/// Concurrency model (VP-D R2) — every field's guard, spelled out:
///
/// queueConfined (touched only inside `queue` blocks or `queue.sync`;
/// no lock needed because the queue serializes them):
///   handle, sessionID, sessionHeaderWritten, configuredURL,
///   nextReopenAllowedAt, nowOverride
///
/// pendingLock-guarded (updated from submit threads and briefly inside queue
/// blocks; never held across disk I/O or while enqueuing):
///   pending, submitted, capDrops, writeDrops, openFailures, writeFailures,
///   retryAttempts, recoveries, hasUnrecoveredFailure, faultBudget
///
/// Lock order is always queue-confined work first, then `pendingLock` for a
/// counter update; no path takes `pendingLock` and then enters the queue, so
/// no deadlock is possible. `_testQueueStats` reads only pendingLock-guarded
/// fields, which keeps it usable while a consumer barrier blocks the queue.
public enum RuntimeTrace {
    public static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.kenyu.voicepointer.mac", isDirectory: true)
        .appendingPathComponent("runtime.log")

    /// Serial writer queue. Owns all queue-confined state and performs every
    /// disk operation.
    private static let queue = DispatchQueue(label: "com.kenyu.VoicePointer.runtime-trace")

    /// Guards submit-side accounting and fault budget only. Never held across
    /// disk I/O.
    private static let pendingLock = NSLock()

    private static let maxPending = 2_048
    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private static let retainedRotations = 3
    /// Minimum monotonic interval between session (re)open attempts after a
    /// failure, so a broken disk cannot be retried once per record. Explicit
    /// transitions (configure/reset/rotation reopen) bypass the limit.
    private static let reopenIntervalNs: UInt64 = 500_000_000

    // queueConfined — see the model comment above.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var sessionID = UUID().uuidString
    nonisolated(unsafe) private static var sessionHeaderWritten = false
    nonisolated(unsafe) private static var configuredURL: URL?
    nonisolated(unsafe) private static var suspendedForDataRemoval = false // queue-confined
    nonisolated(unsafe) private static var nextReopenAllowedAt: UInt64 = 0
    nonisolated(unsafe) private static var nowOverride: UInt64?
    // Same writer queue as the detailed ring. This second sink keeps only
    // closed-vocabulary diagnostics, independent of touch-frame volume.
    nonisolated(unsafe) private static var history = TraceHistoryWriter()

    // pendingLock-guarded — see the model comment above.
    nonisolated(unsafe) private static var pending = 0
    nonisolated(unsafe) private static var submitted: UInt64 = 0
    nonisolated(unsafe) private static var capDrops: UInt64 = 0
    nonisolated(unsafe) private static var writeDrops: UInt64 = 0
    nonisolated(unsafe) private static var openFailures: UInt64 = 0
    nonisolated(unsafe) private static var writeFailures: UInt64 = 0
    nonisolated(unsafe) private static var retryAttempts: UInt64 = 0
    nonisolated(unsafe) private static var recoveries: UInt64 = 0
    nonisolated(unsafe) private static var hasUnrecoveredFailure = false
    nonisolated(unsafe) private static var faultBudget: [TraceFault: Int] = [:]

    private static let monotonicOrigin = DispatchTime.now().uptimeNanoseconds

    /// T12: Drain pending records and close the handle before moving the app's cache to Trash.
    /// The app exits after a successful preparation; late lifecycle records cannot recreate the cache.
    public static func suspendForDataRemoval() {
        queue.sync { suspendedForDataRemoval = true; closeHandle() }
    }

    // MARK: - Testing SPI

    /// Testing-only session configuration; also clears injected faults, the
    /// injected clock, and all counters so checks start deterministic.
    @_spi(Testing)
    public static func configureForTesting(fileURL: URL) {
        queue.sync {
            suspendedForDataRemoval = false
            clearTestHooksAndCounters()
            closeHandle()
            configuredURL = fileURL
            sessionID = UUID().uuidString
            sessionHeaderWritten = false
            nextReopenAllowedAt = 0
            openSessionIfNeeded(now: currentMonotonicNs(), forced: true)
        }
    }

    @_spi(Testing)
    public static func resetTestingConfiguration() {
        queue.sync {
            suspendedForDataRemoval = false
            clearTestHooksAndCounters()
            closeHandle()
            configuredURL = nil
            sessionID = UUID().uuidString
            sessionHeaderWritten = false
            nextReopenAllowedAt = 0
        }
    }

    /// Replaces the monotonic clock used for rate limiting; `nil` restores the
    /// real clock. Must be called while no consumer barrier is active.
    @_spi(Testing)
    public static func _testSetMonotonicClock(_ nanoseconds: UInt64?) {
        queue.sync { nowOverride = nanoseconds }
    }

    /// Makes the next `times` occurrences of `fault` fail deterministically;
    /// `times == 0` clears the budget for that fault.
    @_spi(Testing)
    public static func _testInjectFaults(_ fault: TraceFault, times: Int) {
        precondition(times >= 0, "fault budget must be non-negative")
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if times == 0 { faultBudget[fault] = nil } else { faultBudget[fault] = times }
    }

    /// Enqueues a closure that runs on the writer queue before already
    /// submitted records, letting a test block the consumer deterministically.
    @_spi(Testing)
    public static func _testInsertConsumerBarrier(_ barrier: @escaping @Sendable () -> Void) {
        queue.async(execute: DispatchWorkItem(block: barrier))
    }

    /// Counter snapshot. Reads only pendingLock-guarded fields, so it is safe
    /// to call while a consumer barrier blocks the queue.
    @_spi(Testing)
    public static func _testQueueStats() -> TraceQueueStats {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return TraceQueueStats(
            pending: pending,
            submitted: submitted,
            capDrops: capDrops,
            writeDrops: writeDrops,
            openFailures: openFailures,
            writeFailures: writeFailures,
            retryAttempts: retryAttempts,
            recoveries: recoveries
        )
    }

    /// Current session identity. Recovery deliberately preserves it; only
    /// reset()/configureForTesting mint a new one. Call while the queue is idle.
    @_spi(Testing)
    public static func _testSessionID() -> String {
        queue.sync { sessionID }
    }

    // MARK: - Public API (unchanged signatures)

    public static func reset() {
        queue.sync {
            clearTestHooksAndCounters()
            closeHandle()
            sessionID = UUID().uuidString
            sessionHeaderWritten = false
            let now = currentMonotonicNs()
            openSessionIfNeeded(now: now, forced: true)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            history.append("runtime session version=\(version) build=\(build)", at: Date(),
                           parent: activeURL.deletingLastPathComponent(), session: sessionID,
                           pid: ProcessInfo.processInfo.processIdentifier)
            do { try rotateIfNeeded(now: now) } catch {
                closeHandle()
                noteWriteFailure(now: now)
            }
        }
    }

    public static func record(_ message: String) {
        pendingLock.lock()
        guard pending < maxPending else {
            capDrops &+= 1
            pendingLock.unlock()
            return
        }
        pending += 1
        submitted &+= 1
        pendingLock.unlock()
        queue.async {
            defer {
                pendingLock.lock()
                pending -= 1
                pendingLock.unlock()
            }
            guard !suspendedForDataRemoval else { return }
            let now = currentMonotonicNs()
            openSessionIfNeeded(now: now, forced: false)
            guard let handle else {
                pendingLock.lock()
                writeDrops &+= 1
                pendingLock.unlock()
                return
            }
            let wall = String(format: "%.6f", Date().timeIntervalSince1970)
            history.append(message, at: Date(), parent: activeURL.deletingLastPathComponent(),
                           session: sessionID, pid: ProcessInfo.processInfo.processIdentifier)
            let line = "walltime=\(wall) monotonicNs=\(now) pid=\(ProcessInfo.processInfo.processIdentifier) session=\(sessionID) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                if consumeInjectedFault(.write) { throw FaultInjected.injected }
                try handle.write(contentsOf: data)
            } catch {
                closeHandle()
                noteWriteFailure(now: now)
                pendingLock.lock()
                writeDrops &+= 1
                pendingLock.unlock()
                return
            }
            do { try rotateIfNeeded(now: now) } catch {
                // The triggering line already reached the file; only the
                // rotation failed, so this is not a write drop.
                closeHandle()
                noteWriteFailure(now: now)
            }
        }
    }

    public static func flush() { queue.sync {} }

    // MARK: - Session open / recovery

    /// Opens the session file when the handle is missing. After a failure the
    /// attempt is rate-limited by `reopenIntervalNs` on the monotonic clock;
    /// `forced` bypasses the limit for explicit transitions. The session
    /// identity never changes here — recovery reuses the same sessionID and
    /// only writes a header when none was written (or the file vanished).
    @discardableResult
    private static func openSessionIfNeeded(now: UInt64, forced: Bool) -> Bool {
        if handle != nil { return true }
        if !forced, now < nextReopenAllowedAt { return false }
        pendingLock.lock()
        retryAttempts &+= 1
        pendingLock.unlock()
        if consumeInjectedFault(.openSession) {
            noteOpenFailure(now: now)
            return false
        }

        let url = activeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            noteOpenFailure(now: now)
            return false
        }
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            noteOpenFailure(now: now)
            return false
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            noteOpenFailure(now: now)
            return false
        }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try opened.seekToEnd() } catch {
            try? opened.close()
            noteOpenFailure(now: now)
            return false
        }
        handle = opened
        if !sessionHeaderWritten || !fileExisted {
            do {
                try opened.write(contentsOf: Data(sessionHeader().utf8))
                sessionHeaderWritten = true
            } catch {
                try? opened.close()
                handle = nil
                noteOpenFailure(now: now)
                return false
            }
        }
        noteSuccessfulOpen()
        return true
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private static func noteOpenFailure(now: UInt64) {
        pendingLock.lock()
        openFailures &+= 1
        hasUnrecoveredFailure = true
        pendingLock.unlock()
        nextReopenAllowedAt = saturatingAdd(now, reopenIntervalNs)
    }

    private static func noteWriteFailure(now: UInt64) {
        pendingLock.lock()
        writeFailures &+= 1
        hasUnrecoveredFailure = true
        pendingLock.unlock()
        nextReopenAllowedAt = saturatingAdd(now, reopenIntervalNs)
    }

    /// Counts a successful reopen. Recovery writes one summary line reporting
    /// accumulated drops and failures; the line is written directly (never via
    /// record()), so a failing summary cannot recurse or flood — the next
    /// attempt is bounded by the reopen rate limit.
    private static func noteSuccessfulOpen() {
        let recovered: Bool = pendingLock.withLock {
            guard hasUnrecoveredFailure else { return false }
            hasUnrecoveredFailure = false
            recoveries &+= 1
            return true
        }
        guard recovered, let handle else { return }
        let counters = snapshotCounters()
        let line = "# summary kind=recovered drops=\(counters.writeDrops) capDrops=\(counters.capDrops) openFailures=\(counters.openFailures) writeFailures=\(counters.writeFailures) recoveries=\(counters.recoveries)\n"
        if (try? handle.write(contentsOf: Data(line.utf8))) == nil {
            pendingLock.lock()
            writeFailures &+= 1
            pendingLock.unlock()
        }
    }

    // MARK: - Rotation

    private static func rotateIfNeeded(now: UInt64) throws {
        guard let handle, handle.offsetInFile >= maxFileBytes else { return }
        if consumeInjectedFault(.rotate) { throw FaultInjected.injected }
        closeHandle()
        let url = activeURL
        for index in stride(from: retainedRotations - 1, through: 1, by: -1) {
            let source = rotationURL(index), destination = rotationURL(index + 1)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: url, to: rotationURL(1)) }
        sessionHeaderWritten = false
        openSessionIfNeeded(now: now, forced: true)
    }

    // MARK: - Helpers

    private static var activeURL: URL { configuredURL ?? fileURL }

    /// Monotonic nanoseconds since runtime init, or the injected test value.
    /// queueConfined: read on the queue only, written via queue.sync.
    private static func currentMonotonicNs() -> UInt64 {
        if let overridden = nowOverride { return overridden }
        let origin = monotonicOrigin
        let nowNs = DispatchTime.now().uptimeNanoseconds
        return nowNs >= origin ? nowNs - origin : 0
    }

    /// Returns true once per injected fault occurrence.
    private static func consumeInjectedFault(_ fault: TraceFault) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard var remaining = faultBudget[fault], remaining > 0 else { return false }
        remaining -= 1
        if remaining == 0 { faultBudget[fault] = nil } else { faultBudget[fault] = remaining }
        return true
    }

    private static func clearTestHooksAndCounters() {
        // Called from queue.sync blocks; counters need pendingLock because the
        // submit side touches them concurrently. `pending` is deliberately NOT
        // cleared: it is owned by the increment/decrement pairs around queued
        // blocks, and zeroing it here could race a submit thread's increment
        // and drive the counter negative, silently disabling the 2_048 cap.
        pendingLock.lock()
        submitted = 0
        capDrops = 0
        writeDrops = 0
        openFailures = 0
        writeFailures = 0
        retryAttempts = 0
        recoveries = 0
        hasUnrecoveredFailure = false
        faultBudget = [:]
        pendingLock.unlock()
        nowOverride = nil
    }

    private static func snapshotCounters() -> TraceQueueStats {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return TraceQueueStats(
            pending: pending,
            submitted: submitted,
            capDrops: capDrops,
            writeDrops: writeDrops,
            openFailures: openFailures,
            writeFailures: writeFailures,
            retryAttempts: retryAttempts,
            recoveries: recoveries
        )
    }

    private static func sessionHeader() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "# session=\(sessionID) startedWalltime=\(String(format: "%.6f", Date().timeIntervalSince1970)) pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version) build=\(build)\n"
    }

    private static func rotationURL(_ index: Int) -> URL { URL(fileURLWithPath: activeURL.path + ".\(index)") }
    private static func closeHandle() {
        try? handle?.close(); handle = nil
        history.close()
    }
}

/// A separate, bounded 30-calendar-day history. Field values are deliberately
/// closed: arbitrary text, application names, addresses and keys never enter
/// this archive, even if a caller accidentally supplies them.
@_spi(Testing)
public enum TraceHistoryPolicy {
    public static let days = 30
    public static let maximumDailyBytes = 4 * 1024 * 1024
    private static let prefixes: [(String, String)] = [
        ("runtime session ", "session"), ("application launched", "launch"),
        ("application terminated", "terminate"),
        ("composer send ", "send"), ("doubao send ", "doubaoSend"),
        ("composer action outcome=", "action"), ("composer session rejected ", "targetRejected"),
        ("composer input security ", "inputSecurity"), ("composer target watch notification=", "targetWatch"),
        ("coordinator gesture ignored ", "gestureRejected"), ("speech backend ", "backend"),
        ("capture open ", "capture"), ("capture fallback ", "captureFallback"),
        ("capture start failed ", "captureFailure"), ("capture_route ", "captureRoute"),
        ("audio meter ", "meter"), ("microphone monitor ", "microphone"),
        ("main slow ", "mainSlow"), ("main stall ", "mainHang"),
        ("output duck ", "duck"), ("hud sound ", "hudSound"),
        ("issue ", "issue"), ("voice issue ", "issue"),
        ("permission guidance ", "permissionMissing")
    ]
    private static let numbers: Set<String> = [
        "ms", "elapsedMs", "releaseToReturnMs", "returnToConfirmMs", "retry", "late", "changesMs",
        "originalEmpty", "firstEmpty", "systemSecure", "status", "hwRate", "ch", "firstCallbackMs",
        "firstNonzeroMs", "callbacks", "nonzero", "zero", "reopens", "count", "frames", "durationMs",
        "early", "localHotwords", "pending", "peak", "p95"
    ]
    private static let enums: [String: Set<String>] = [
        "mode": ["doubao", "voiceNative", "noTarget", "stream", "upload"],
        "route": ["doubao", "qwen06-rolling", "qwen17-rolling", "apple-speech", "aliyun", "groq-v3", "groq-turbo"],
        "hybrid": ["aliyun", "groq", "openai", "siliconflow", "off"],
        "backend": ["auhal", "engine"], "device": ["builtin", "bluetooth", "usb", "aggregate", "other"],
        "default": ["builtin", "bluetooth", "usb", "aggregate", "other", "unknown"],
        "stage": ["new", "enableIO", "setDevice", "format", "init", "start", "stop"],
        "phase": ["beforeReturn", "afterReturn", "returnAttempt", "returnPosted", "returnPostFailed",
                  "emptyBeforeReturn", "select", "sealed", "idle", "resolvingTarget", "listening", "releasing"],
        "observation": ["editorReplaced", "windowChanged", "applicationSwitched", "focusChanged",
                        "sessionInactive", "emptyBeforeReturn", "confirmed", "unchanged", "changedNonempty",
                        "textStillPresent", "unreadable", "clearUnstable", "returnedToEmptyHint", "rememberedEmptyHint"],
        "decision": ["useOriginalSettle", "unchangedNonempty", "emptyUnchanged", "waitForSpeechText"],
        "heard": ["speech", "silence", "unknown"],
        "code": ["MICROPHONE_NO_SOUND", "MICROPHONE_ROUTE_FAILED", "MICROPHONE_REOPEN_FAILED",
                 "LOCAL_WORKER_FAILED", "LOCAL_MODEL_MISSING", "LOCAL_MODEL_CORRUPT", "GROQ_TRANSCRIBE_FAILED",
                 "ALI_STREAM_FAILED", "API_KEY_INVALID", "API_KEY_MISSING", "NETWORK_FAILED", "RESPONSE_TIMEOUT"],
        "notification": ["focusElement", "focusWindow", "workspace", "other"],
        "field": ["ordinary", "secure"], "delivery": ["finalOnly"],
        "result": ["ok", "failed", "confirmed", "unconfirmed", "landed", "timeout", "restored", "skipped"],
        "reason": ["secureInput", "accessibilityUnavailable", "noFrontmostApplication", "wrongProcess",
                   "noFocusedElement", "notEditable", "frozenTargetMismatch", "noTargetWindow",
                   "targetWatchUnavailable", "targetChangedDuringAcquire", "previousBackendBusy", "backendBusy",
                   "activeStatus", "releasePending", "cancelled", "invalidSelection", "invalidConfiguration",
                   "cloudAdmission", "textChangedAfterSettle", "startFailed", "noCallbacks", "allZero",
                   "formatChanged", "routeChanged"],
        "outcome": ["kept", "inputSubmitted", "sent", "nothingToSend", "removedCurrentDictation", "clearedCurrentInput",
                    "clearArmed", "nothingToCancel", "targetChanged", "sendTargetChangedBeforeReturn",
                    "unsafeToCancel", "eventPostFailed", "sendUnconfirmed", "sendStillPresent",
                    "deliveryFailed", "deliveryUnconfirmed", "finalCopiedToClipboard", "cancelUnconfirmed",
                    "dictationNotSettled", "doubaoTextTimeout", "undoSubmitted"]
    ]
    private static let flags: Set<String> = [
        "submitted", "matchesFrozenIdentity", "didInvalidate", "alreadyCancelled", "played", "started",
        "valueReadable", "empty", "blank",
        "accessibilityMissing", "inputMonitoringMissing", "eventPostingMissing"
    ]
    public static func project(_ message: String) -> String? {
        guard message.utf8.count <= 4096,
              let event = prefixes.first(where: { message.hasPrefix($0.0) })?.1 else { return nil }
        var fields = ["event=" + event]
        for token in message.split(whereSeparator: { $0.isWhitespace }).prefix(64) {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]), value = String(pair[1])
            let numeric = numbers.contains(key) &&
                value.range(of: "^-?[0-9]{1,20}(\\.[0-9]{1,6})?$", options: .regularExpression) != nil
            let version = ["version", "build"].contains(key) &&
                value.range(of: "^[0-9]{1,8}(\\.[0-9]{1,8}){0,3}$", options: .regularExpression) != nil
            if numeric || version || enums[key]?.contains(value) == true ||
                (flags.contains(key) && ["true", "false", "unknown", "0", "1"].contains(value)) {
                fields.append(key + "=" + value)
            }
        }
        return fields.joined(separator: " ")
    }
    public static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
    public static func retains(day: Int, now: Date) -> Bool {
        let age = self.day(now) - day
        return age >= 0 && age < days
    }
}

/// Queue-confined to RuntimeTrace.queue. Files use UTC epoch-day names so
/// daylight-saving changes and timezone changes cannot rotate twice in a day.
private final class TraceHistoryWriter {
    private var handle: FileHandle?
    private var activeDay: Int?
    private var activeParent: URL?
    private var bytes = 0
    private var capped = false
    private var lastPrunedDay: Int?
    func close() { try? handle?.close(); handle = nil; activeDay = nil; activeParent = nil }

    func append(_ message: String, at date: Date, parent: URL, session: String, pid: pid_t) {
        guard let projected = TraceHistoryPolicy.project(message) else { return }
        let day = TraceHistoryPolicy.day(date)
        let directory = parent.appendingPathComponent("important-history", isDirectory: true)
        if activeDay != day || activeParent != directory || handle == nil {
            close()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { return }
                if lastPrunedDay != day {
                    // Only our own finite numeric filenames can be retired.
                    // Failed Trash moves leave the file untouched.
                    for url in try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                        let name = url.lastPathComponent
                        guard name.hasPrefix("day-"), name.hasSuffix(".log"),
                              let storedDay = Int(name.dropFirst(4).dropLast(4)),
                              storedDay < day - (TraceHistoryPolicy.days - 1),
                              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                              values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    lastPrunedDay = day
                }
                let file = directory.appendingPathComponent("day-\(day).log")
                let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return }
                var st = stat()
                guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                    Darwin.close(fd); return
                }
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                bytes = Int(st.st_size); capped = bytes >= TraceHistoryPolicy.maximumDailyBytes - 128
                activeDay = day; activeParent = directory
            } catch { close(); return }
        }
        guard !capped, let handle else { return }
        let wall = String(format: "%.6f", date.timeIntervalSince1970)
        let data = Data("walltime=\(wall) pid=\(pid) session=\(session) \(projected)\n".utf8)
        do {
            if bytes + data.count > TraceHistoryPolicy.maximumDailyBytes - 128 {
                let marker = Data("walltime=\(wall) event=historyDailyCap reached=1\n".utf8)
                if bytes + marker.count <= TraceHistoryPolicy.maximumDailyBytes {
                    try handle.write(contentsOf: marker)
                }
                capped = true
            } else {
                try handle.write(contentsOf: data); bytes += data.count
            }
        } catch { close() }
    }
}

/// Queue and fault statistics for the Testing SPI. All counters are
/// pendingLock-guarded at the source.
@_spi(Testing)
public struct TraceQueueStats: Sendable, Equatable {
    public var pending: Int
    public var submitted: UInt64
    public var capDrops: UInt64
    public var writeDrops: UInt64
    public var openFailures: UInt64
    public var writeFailures: UInt64
    public var retryAttempts: UInt64
    public var recoveries: UInt64

    public init(
        pending: Int,
        submitted: UInt64,
        capDrops: UInt64,
        writeDrops: UInt64,
        openFailures: UInt64,
        writeFailures: UInt64,
        retryAttempts: UInt64,
        recoveries: UInt64
    ) {
        self.pending = pending
        self.submitted = submitted
        self.capDrops = capDrops
        self.writeDrops = writeDrops
        self.openFailures = openFailures
        self.writeFailures = writeFailures
        self.retryAttempts = retryAttempts
        self.recoveries = recoveries
    }
}
