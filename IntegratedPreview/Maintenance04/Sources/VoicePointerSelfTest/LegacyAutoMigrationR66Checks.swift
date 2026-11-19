import Foundation
@_spi(Testing) import VoicePointerCore

/// R66's one migration test group. All words and directories are synthetic.
enum LegacyAutoMigrationR66Checks {
    private struct Document: Codable {
        var version: Int
        var terms: [LexiconTerm]
    }

    private static func errorCategory(_ error: Error) -> String {
        guard let failure = error as? LexiconStore.StoreError else { return "nonStore" }
        switch failure {
        case .notLoaded: return "notLoaded"
        case .unavailable: return "unavailable"
        case .malformed: return "malformed"
        case .unsupportedVersion: return "unsupportedVersion"
        case .validation: return "validation"
        case .changedOnDisk: return "changedOnDisk"
        }
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            if !condition { failures.append("r66 migration: \(name)") }
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                       isDirectory: true)
            .appendingPathComponent("R66MigrationSynthetic-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return ["r66 migration: temporary-directory creation failed"]
        }
        defer { try? fm.removeItem(at: root) }

        let entries: [LexiconTerm] = (0..<2_000).map { number in
            LexiconTerm(canonical: "SyntheticCorrect\(number)",
                        variants: ["SyntheticWrong\(number)"],
                        source: number < 1_990 ? .automaticallyLearned : .manual)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture: Data
        do {
            fixture = try encoder.encode(Document(version: LexiconStore.currentVersion, terms: entries))
        } catch {
            return ["r66 migration: fixture encoding failed"]
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")

        var successStage = "create"
        do {
            let directory = root.appendingPathComponent("success", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            successStage = "writeFixture"
            let liveURL = directory.appendingPathComponent(LexiconStore.fileName)
            // Synthetic fixture creation is not the production atomic writer under test.
            try fixture.write(to: liveURL)
            successStage = "readFixture"
            let sourceBytes = try Data(contentsOf: liveURL)
            let store = LexiconStore(directory: directory)
            successStage = "load"
            _ = try await store.load()
            successStage = "archive"
            let first = try await store.archiveLegacyAutomaticTerms(now: now)
            successStage = "readback"
            expect(first.moved == 1_990 && first.kept == 10, "moved/kept counts")
            let remaining = await store.allTerms()
            expect(remaining.count == 10 && remaining.allSatisfy { $0.source == .manual },
                   "live file preserves manual terms")
            let archiveData = try Data(contentsOf: directory.appendingPathComponent("auto-learned-archive.json"))
            let archive = try decoder.decode(Document.self, from: archiveData)
            expect(archive.terms.count == 1_990 &&
                   archive.terms.allSatisfy { $0.source == .automaticallyLearned },
                   "archive contains all synthetic automatic terms")
            let backupURL = directory.appendingPathComponent("backup-before-0.5.66-\(stamp).json")
            expect(try Data(contentsOf: backupURL) == sourceBytes, "backup is byte-identical")
            let firstLiveBytes = try Data(contentsOf: liveURL)
            let relaunched = LexiconStore(directory: directory)
            _ = try await relaunched.load()
            let repeated = try await relaunched.archiveLegacyAutomaticTerms(now: now)
            expect(repeated.moved == 0 && repeated.kept == 10, "relaunch is a no-op")
            expect(try Data(contentsOf: liveURL) == firstLiveBytes, "relaunch preserves live bytes")
            expect(try Data(contentsOf: directory.appendingPathComponent("auto-learned-archive.json")) == archiveData,
                   "relaunch does not rewrite archive")
        } catch {
            failures.append("r66 migration: success-path stage=\(successStage) category=\(errorCategory(error))")
        }

        var failureStage = "create"
        do {
            let directory = root.appendingPathComponent("failed-write", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            failureStage = "writeFixture"
            let liveURL = directory.appendingPathComponent(LexiconStore.fileName)
            try fixture.write(to: liveURL)
            failureStage = "readFixture"
            let exactOriginalBytes = try Data(contentsOf: liveURL)
            let store = LexiconStore(directory: directory)
            failureStage = "load"
            _ = try await store.load()
            failureStage = "injectedCommit"
            var failedAtCommit = false
            do {
                _ = try await store.archiveLegacyAutoFailingCommitForTest(now: now)
            } catch {
                failedAtCommit = true
            }
            expect(failedAtCommit, "simulated live-file write fails")
            expect(try Data(contentsOf: liveURL) == exactOriginalBytes,
                   "failed live-file write preserves every original byte")
            let stillLoaded = await store.allTerms()
            expect(stillLoaded.count == 2_000, "failed write preserves loaded terms")
        } catch {
            failures.append("r66 migration: failure-path stage=\(failureStage) category=\(errorCategory(error))")
        }

        return failures
    }
}
