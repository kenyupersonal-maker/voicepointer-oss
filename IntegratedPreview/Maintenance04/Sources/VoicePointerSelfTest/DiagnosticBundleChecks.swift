import Foundation
import VoicePointerCore

@MainActor enum DiagnosticBundleChecks {
    static func run() async -> [String] {
        var failures: [String] = [], cases = 0
        func check(_ result: Bool, _ code: String) {
            cases += 1; if !result { failures.append("event=diagnostic_checks,state=failed,case=" + code) }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/diagnostic-fixtures/" + UUID().uuidString, isDirectory: true)
        let logs = root.appendingPathComponent("logs"), work = root.appendingPathComponent("work"), trash = root.appendingPathComponent("Trash")
        let key = "SYNTHETIC_KEY_SENTINEL_91", text = "SYNTHETIC_TEXT_SENTINEL_92", audio = "SYNTHETIC_AUDIO_SENTINEL_93"
        let summary = DiagnosticSummary(version: "0.5.52", build: "20261002.1", cpuCount: 8, memoryBytes: 16 << 30,
            osMajor: 26, mode: .voiceNative, routeID: "qwen06-rolling", lexiconEnabled: false,
            correctionLearning: false, enhancementLearning: false, onlineEnhancement: false)
        func trashFixture(_ url: URL) throws {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        func export(_ name: String, _ value: DiagnosticSummary? = nil) throws -> (URL, UInt64) {
            let destination = root.appendingPathComponent(name)
            return (destination, try DiagnosticBundle.export(summary: value ?? summary, logDirectory: logs,
                workspaceParent: work, destination: destination, trash: trashFixture))
        }
        func entry(_ archive: URL, _ name: String) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, name]
            process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DiagnosticBundleFailure.archive }
            return data
        }
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let input = "state=ready count=7 key=\(key) text=\(text) audio=\(audio)\n" +
                "state=\(text) profile=\(key) count=12\n" + "unstructured \(key) \(text) \(audio)\n"
            let current = logs.appendingPathComponent("runtime.log")
            try Data(input.utf8).write(to: current)
            for n in 1...3 { try Data("state=stopped count=\(n)\n".utf8).write(to: logs.appendingPathComponent("runtime.log.\(n)")) }
            try Data("count=9999999 \(key)\n".utf8).write(to: logs.appendingPathComponent("runtime.log.4"))
            try Data(audio.utf8).write(to: logs.appendingPathComponent("recording.marker"))
            let (package, size) = try export("safe.zip")
            check(size > 0 && size <= UInt64(DiagnosticBundle.maximumArchiveBytes), "archive_size")
            let contents = try ["summary.json", "runtime-redacted.log", "limits.json"].map { try entry(package, $0) }
            let joined = contents.reduce(Data(), +)
            for sentinel in [key, text, audio] { check(joined.range(of: Data(sentinel.utf8)) == nil, "decompressed_sentinel_absent") }
            let runtime = String(decoding: contents[1], as: UTF8.self)
            check(runtime.contains("count=7") && runtime.contains("state=ready"), "numeric_and_enum_retained")
            check(!runtime.contains("9999999"), "only_four_source_files")
            check(try Data(contentsOf: current) == Data(input.utf8), "source_unchanged")
            check(DiagnosticBundle.sanitizedLine("state=\(text) key=\(key)") == nil, "unknown_values_drop")
            check(DiagnosticBundle.sanitizedLine(String(repeating: "1", count: 1_025)) == nil, "long_line_drop")
            let invalid = DiagnosticSummary(version: key, build: text, cpuCount: 1, memoryBytes: 1, osMajor: 26,
                mode: .doubao, routeID: audio, lexiconEnabled: false, correctionLearning: false,
                enhancementLearning: false, onlineEnhancement: false)
            let (invalidPackage, _) = try export("unknown-fields.zip", invalid)
            let projected = try entry(invalidPackage, "summary.json")
            check([key, text, audio].allSatisfy { projected.range(of: Data($0.utf8)) == nil }, "summary_closed_projection")

            // Existing destinations survive failed publication, and the ViewModel makes the failure visible.
            let existing = root.appendingPathComponent("existing.zip"), original = Data("synthetic_original".utf8)
            try original.write(to: existing)
            do { _ = try export("existing.zip"); check(false, "existing_rejected") }
            catch { check(true, "existing_rejected") }
            check(try Data(contentsOf: existing) == original, "failed_publish_preserves_old")
            let vm = DiagnosticExportViewModel()
            await vm.export { throw DiagnosticBundleFailure.destination }
            check(vm.state == .failed && !vm.isRunning, "failure_visible")
            await vm.export { 123 }
            check(vm.state == .exported(123), "success_visible_and_retry")

            let many = (0..<1_100).map { "count=\($0) state=ready" }.joined(separator: "\n")
            try Data(many.utf8).write(to: current)
            let (bounded, _) = try export("bounded.zip")
            let limits = try JSONSerialization.jsonObject(with: entry(bounded, "limits.json")) as? [String: Any]
            check((limits?["retained_lines"] as? Int) == DiagnosticBundle.maximumRetainedLines, "line_budget")
            let handle = try FileHandle(forWritingTo: current)
            try handle.truncate(atOffset: 20_000_000); try handle.close()
            let (huge, hugeSize) = try export("huge-source.zip")
            check(hugeSize <= UInt64(DiagnosticBundle.maximumArchiveBytes), "huge_input_bounded")
            check(try entry(huge, "runtime-redacted.log").count <= 256_000, "read_tail_budget")
            try Data([0xFF, 0xFE]).write(to: current)
            let (invalidEncoding, _) = try export("invalid-encoding.zip")
            check(!(try entry(invalidEncoding, "runtime-redacted.log")).contains(0xFF), "invalid_encoding_drop")

            // A symlink in the exact input filename is rejected before its target can be read.
            let sealed = root.appendingPathComponent("original-log")
            try FileManager.default.moveItem(at: current, to: sealed)
            try FileManager.default.createSymbolicLink(at: current, withDestinationURL: sealed)
            do { _ = try export("linked.zip"); check(false, "input_link_rejected") }
            catch { check(true, "input_link_rejected") }
            check(try Data(contentsOf: sealed) == Data([0xFF, 0xFE]), "outside_link_target_unchanged")
            let linkedParent = root.appendingPathComponent("linked-work")
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: work)
            do {
                _ = try DiagnosticBundle.export(summary: summary, logDirectory: logs, workspaceParent: linkedParent,
                    destination: root.appendingPathComponent("linked-parent.zip"), trash: trashFixture)
                check(false, "workspace_link_rejected")
            } catch { check(true, "workspace_link_rejected") }
        } catch { check(false, "fixture_operation") }
        print("event=diagnostic_checks,state=\(failures.isEmpty ? "passed" : "failed"),cases=\(cases),synthetic=1,real_logs_read=0")
        return failures
    }
}
