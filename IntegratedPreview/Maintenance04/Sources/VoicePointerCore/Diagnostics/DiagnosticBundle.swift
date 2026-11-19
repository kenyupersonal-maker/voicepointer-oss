import Foundation
import Darwin
import Observation

@Observable @MainActor
public final class DiagnosticExportViewModel {
    public enum State: Sendable, Equatable { case idle, exporting, exported(UInt64), failed }
    public private(set) var state: State = .idle
    public var isRunning: Bool { state == .exporting }
    public init() {}
    public func export(operation: @escaping @Sendable () throws -> UInt64) async {
        guard !isRunning else { return }
        state = .exporting
        do { state = .exported(try await Task.detached(priority: .utility, operation: operation).value) }
        catch { state = .failed }
    }
}

public enum DiagnosticBundleFailure: Error, Sendable { case unsafePath, input, archive, destination }

/// Only this typed projection is exported; preferences, endpoint names and user text never enter the encoder.
public struct DiagnosticSummary: Sendable {
    public let version: String, build: String
    public let cpuCount: Int, memoryBytes: UInt64, osMajor: Int
    public let mode: VoiceInputMode
    public let routeID: String
    public let lexiconEnabled: Bool, correctionLearning: Bool, enhancementLearning: Bool, onlineEnhancement: Bool
    public init(version: String, build: String, cpuCount: Int, memoryBytes: UInt64, osMajor: Int,
                mode: VoiceInputMode, routeID: String, lexiconEnabled: Bool, correctionLearning: Bool,
                enhancementLearning: Bool, onlineEnhancement: Bool) {
        self.version = version; self.build = build; self.cpuCount = cpuCount; self.memoryBytes = memoryBytes
        self.osMajor = osMajor; self.mode = mode; self.routeID = routeID; self.lexiconEnabled = lexiconEnabled
        self.correctionLearning = correctionLearning; self.enhancementLearning = enhancementLearning
        self.onlineEnhancement = onlineEnhancement
    }
    fileprivate var fields: [String: Any] {
        func release(_ value: String) -> String {
            value.range(of: "^[0-9]{1,14}(\\.[0-9]{1,6}){0,3}$", options: .regularExpression) == nil ? "unknown" : value
        }
        let routes: Set<String> = ["qwen06-rolling", "qwen17-rolling", "apple-speech", "aliyun", "groq-v3", "groq-turbo"]
        return ["version": release(version), "build": release(build), "cpu_count": max(0, cpuCount),
            "memory_bytes": memoryBytes, "os_major": max(0, osMajor), "mode": mode.rawValue,
            "route": routes.contains(routeID) ? routeID : "unknown", "lexicon_enabled": lexiconEnabled,
            "correction_learning": correctionLearning, "enhancement_learning": enhancementLearning,
            "online_enhancement": onlineEnhancement]
    }
}

public enum DiagnosticBundle {
    public static let maximumArchiveBytes = 256_000
    public static let maximumLogReadBytes = 262_144
    public static let maximumRetainedLines = 1_024
    private static let numeric: Set<String> = ["t", "ms", "count", "pending", "submitted", "dropped", "capDrops",
        "writeDrops", "openFailures", "writeFailures", "retryAttempts", "recoveries", "cpu", "memory",
        "audioMs", "computeMs", "bytes", "frames", "samples", "partials", "finalAudioMs", "finalComputeMs",
        "firstComputeMs", "rules", "hits", "utf16", "physicalStarts", "capture", "cloud", "elapsed_ms", "generation",
        "handshakeMs", "connectMs", "taskStartMs", "workerMs", "audibleWaitMs", "keyReadMs", "startMs", "decodeMs", "hwRate", "ch"]
    private static let signedNumeric: Set<String> = ["status", "firstCallbackMs", "firstNonzeroMs"]
    private static let values: [String: Set<String>] = [
        "state": ["idle", "starting", "ready", "listening", "stopping", "stopped", "failed", "passed", "done", "checking"],
        "event": ["engine_check"], "method": ["doubao", "local", "online"],
        "source": ["check", "dictation", "cache"], "path": ["direct", "system"],
        "reason": Set(HealthFailureReason.allCases.map(\.rawValue)).union(["none", "startFailed", "noCallbacks", "allZero"]),
        "backend": ["auhal", "engine"],
        "device": ["builtin", "bluetooth", "usb", "aggregate", "other"],
        "default": ["builtin", "bluetooth", "usb", "aggregate", "other"],
        "from": ["builtin", "bluetooth", "usb", "aggregate", "other"],
        "to": ["builtin", "bluetooth", "usb", "aggregate", "other"],
        "stage": ["new", "enableIO", "setDevice", "format", "init", "start"],
        "phase": ["idle", "resolvingTarget", "listening", "failed", "starting", "stopping"],
        "mode": ["doubao", "voiceNative", "hold", "toggle"],
        "profile": ["qwen06-rolling", "qwen17-rolling", "apple-speech", "aliyun", "groq-v3", "groq-turbo"],
        "action": ["stop", "cancel", "send"], "enabled": ["true", "false"], "ok": ["true", "false"],
        "stripped": ["0", "1"], "restored": ["0", "1"], "teacher": ["cloud", "doubao"],
        "decision": ["echo", "tooDifferent", "expired", "cancelled", "filtered", "unauthorized", "unchanged", "verified", "candidate", "commonWord", "cap", "duplicate", "notSaved", "notPending"],
        "result": ["skipped", "matched", "notMatched"]]

    /// Unknown keys/free text are discarded, and values for nonnumeric fields have a closed enum vocabulary.
    public static func sanitizedLine(_ line: String) -> String? {
        guard line.utf8.count <= 1_024 else { return nil }
        let regex = try! NSRegularExpression(pattern: "(?:^|[ ,])([A-Za-z][A-Za-z0-9_]*)=([^ ,]+)")
        let range = NSRange(line.startIndex..., in: line)
        var allowed: [String: String] = [:]
        for match in regex.matches(in: line, range: range) {
            guard let k = Range(match.range(at: 1), in: line), let v = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[k]), value = String(line[v])
            if numeric.contains(key), value.range(of: "^[0-9]{1,20}(\\.[0-9]{1,6})?$", options: .regularExpression) != nil {
                allowed[key] = value
            } else if signedNumeric.contains(key), value.range(of: "^-?[0-9]{1,20}$", options: .regularExpression) != nil {
                allowed[key] = value
            } else if values[key]?.contains(value) == true { allowed[key] = value }
        }
        guard !allowed.isEmpty else { return nil }
        return allowed.keys.sorted().map { $0 + "=" + allowed[$0]! }.joined(separator: ",")
    }

    private static func safeAncestors(_ url: URL) throws {
        guard url.isFileURL, url.path == url.standardizedFileURL.path, !url.pathComponents.contains(".."),
              !url.pathComponents.contains("keep-0.5.50") else { throw DiagnosticBundleFailure.unsafePath }
        var part = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            part.appendPathComponent(component)
            var info = stat()
            if lstat(part.path, &info) == 0 {
                guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw DiagnosticBundleFailure.unsafePath }
            } else if errno != ENOENT { throw DiagnosticBundleFailure.unsafePath }
        }
    }
    private static func directory(_ url: URL) throws -> Int32 {
        try safeAncestors(url)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw DiagnosticBundleFailure.unsafePath }
        return fd
    }
    private static func recentLog(_ name: String, directory fd: Int32) throws -> [String] {
        let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if input < 0 {
            if errno == ENOENT { return [] }
            throw DiagnosticBundleFailure.unsafePath
        }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw DiagnosticBundleFailure.unsafePath
        }
        let offset = max(0, info.st_size - off_t(maximumLogReadBytes))
        guard lseek(input, offset, SEEK_SET) >= 0 else { throw DiagnosticBundleFailure.input }
        var bytes = [UInt8](repeating: 0, count: maximumLogReadBytes)
        let count = read(input, &bytes, bytes.count)
        guard count >= 0 else { throw DiagnosticBundleFailure.input }
        guard let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // A tail can begin halfway through a record.
        return lines.compactMap(sanitizedLine)
    }

    /// The injected Trash action lets tests stay entirely in their synthetic HOME.
    public static func export(summary: DiagnosticSummary, logDirectory: URL, workspaceParent: URL,
        destination: URL, trash: (URL) throws -> Void = { url in
            var moved: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
        }) throws -> UInt64 {
        try safeAncestors(logDirectory); try safeAncestors(workspaceParent); try safeAncestors(destination)
        guard !destination.lastPathComponent.isEmpty else { throw DiagnosticBundleFailure.destination }
        try FileManager.default.createDirectory(at: workspaceParent, withIntermediateDirectories: true)
        let stage = workspaceParent.appendingPathComponent("diagnostic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? trash(stage) }
        var logs: [String] = []
        if FileManager.default.fileExists(atPath: logDirectory.path) {
            let fd = try directory(logDirectory); defer { close(fd) }
            // Older rotations first, then the current file; only this fixed four-file set can be opened.
            for name in ["runtime.log.3", "runtime.log.2", "runtime.log.1", "runtime.log"] {
                logs.append(contentsOf: try recentLog(name, directory: fd))
                logs = Array(logs.suffix(maximumRetainedLines))
            }
        }
        let metadata: [String: Data] = [
            "summary.json": try JSONSerialization.data(withJSONObject: summary.fields, options: [.sortedKeys]),
            "runtime-redacted.log": Data((logs.joined(separator: "\n") + "\n").utf8),
            "limits.json": try JSONSerialization.data(withJSONObject: ["schema": 1, "source_files_max": 4,
                "read_bytes_per_file_max": maximumLogReadBytes, "retained_lines_max": maximumRetainedLines,
                "archive_bytes_max": maximumArchiveBytes, "retained_lines": logs.count], options: [.sortedKeys])]
        for (name, data) in metadata { try data.write(to: stage.appendingPathComponent(name)) }
        let archive = stage.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stage
        process.environment = ["HOME": stage.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.arguments = ["-q", "-j", archive.path] + metadata.keys.sorted()
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagnosticBundleFailure.archive }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= maximumArchiveBytes else {
            throw DiagnosticBundleFailure.archive
        }
        let compressed = try Data(contentsOf: archive)
        let parent = destination.deletingLastPathComponent(), parentFD = try directory(parent)
        defer { close(parentFD) }
        let temporaryName = ".VoicePointer-diagnostics-" + UUID().uuidString + ".zip"
        let temporaryURL = parent.appendingPathComponent(temporaryName)
        let fd = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DiagnosticBundleFailure.destination }
        var published = false
        defer { close(fd); if !published { try? trash(temporaryURL) } }
        try compressed.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw DiagnosticBundleFailure.destination }
                written += n
            }
        }
        guard fsync(fd) == 0,
              renameatx_np(parentFD, temporaryName, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw DiagnosticBundleFailure.destination
        }
        published = true
        return UInt64(compressed.count)
    }
}
