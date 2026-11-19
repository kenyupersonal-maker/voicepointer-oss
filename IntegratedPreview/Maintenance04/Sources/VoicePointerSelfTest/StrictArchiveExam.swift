import Darwin
import Foundation
@_spi(Testing) import VoicePointerCore

/// Explicit, read-only, numeric-only exam of the isolated migration archive.
/// This is NOT part of normal self-test execution and never writes any result file.
/// The original teacher context does not exist; test EVERY original pair under R5 without altering the denominator.
@MainActor
enum StrictArchiveExam {
    private struct Archive: Decodable {
        let version: Int
        let terms: [LexiconTerm]
    }

    private static func readRegularFile(_ path: String) throws -> Data {
        enum InputError: Error { case unreadable }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InputError.unreadable }
        defer { _ = close(fd) }
        var statResult = stat()
        guard fstat(fd, &statResult) == 0,
              (statResult.st_mode & S_IFMT) == S_IFREG,
              statResult.st_uid == geteuid(),
              statResult.st_size >= 0,
              statResult.st_size <= 64 * 1024 * 1024 else { throw InputError.unreadable }
        var input = Data()
        input.reserveCapacity(Int(statResult.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n >= 0 else { throw InputError.unreadable }
            if n == 0 { break }
            input.append(contentsOf: buffer.prefix(n))
            if input.count > 64 * 1024 * 1024 { throw InputError.unreadable }
        }
        return input
    }

    /// The caller first copies the explicitly authorized lexicon into this repository's cache.
    /// Only that copy is migrated; this mode refuses Application Support and reads no defaults.
    static func migrateAndRun(isolatedDirectory: String) async -> Bool {
        let directory = URL(fileURLWithPath: isolatedDirectory, isDirectory: true).standardizedFileURL
        let cache = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true).standardizedFileURL
        guard directory.path.hasPrefix(cache.path + "/"),
              directory.lastPathComponent.hasPrefix("r66-strict-real-exam-"),
              directory.resolvingSymlinksInPath() == directory else {
            print("learn migration copied=0 backupEqual=0 passed=0")
            return false
        }
        do {
            let source = directory.appendingPathComponent(LexiconStore.fileName)
            let original = try readRegularFile(source.path)
            let store = LexiconStore(directory: directory)
            _ = try await store.load()
            let result = try await store.archiveLegacyAutomaticTerms()
            let backups = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter {
                    $0.lastPathComponent.hasPrefix("backup-before-0.5.66-")
                }
            var backupEqual = false
            if backups.count == 1 { backupEqual = try readRegularFile(backups[0].path) == original }
            print("learn migration moved=\(result.moved) kept=\(result.kept) backupEqual=\(backupEqual ? 1 : 0)")
            guard backupEqual else { return false }
            return run(archivePath: directory.appendingPathComponent("auto-learned-archive.json").path)
        } catch {
            print("learn migration copied=1 backupEqual=0 passed=0")
            return false
        }
    }

    @discardableResult
    static func run(archivePath: String) -> Bool {
        var counts = Dictionary(uniqueKeysWithValues:
            StrictLearningFilter.Rejection.allCases.map { ($0, 0) }
        )
        var total = 0
        var rejected = 0
        var readable = false
        // Refuse unexpected filenames, but never print even a directory or input path.
        if URL(fileURLWithPath: archivePath).lastPathComponent == "auto-learned-archive.json" {
            do {
                let data = try readRegularFile(archivePath)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let document = try decoder.decode(Archive.self, from: data)
                if document.version == LexiconStore.currentVersion {
                    readable = true
                    // NEVER skip a term because a context sentence is missing; every available
                    // wrong->right pair contributes exactly once to the denominator.
                    for term in document.terms {
                        for wrong in term.variants {
                            total += 1
                            if let reason = StrictLearningFilter.validatePair(
                                variant: wrong, canonical: term.canonical,
                                commonChinese: { _ in false },
                                ordinaryEnglish: { _ in false }
                            ) {
                                rejected += 1
                                counts[reason, default: 0] += 1
                            }
                        }
                    }
                }
            } catch {
                readable = false
            }
        }
        let rejectionRate = total > 0 ? Double(rejected) * 100 / Double(total) : 0
        let passed = readable && total > 0 && rejectionRate >= 95 && abs(rejectionRate - 97.48) <= 1.5
        print("learn exam total=\(total) rejected=\(rejected) rate=\(String(format: "%.2f", rejectionRate)) passed=\(passed ? 1 : 0)")
        for reason in StrictLearningFilter.Rejection.allCases {
            print("learn exam reason=\(reason.rawValue) count=\(counts[reason, default: 0])")
        }
        // No word, transcript, path, Key, audio, sentence or file contents can reach stdout.
        return passed
    }
}
