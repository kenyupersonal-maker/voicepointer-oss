import Foundation
import CryptoKit
import VoicePointerCore

enum ModelResourceLibraryChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append(label) } }
        // Darwin Foundation can retain a system temporary directory despite TMPDIR. The source gate
        // permits writes only inside this repository, so fixture paths must be explicitly scoped here.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/maintenance04-build/model-library-" + UUID().uuidString)
        let library = ModelResourceLibrary(root: root)
        let bytes = Data([120])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var stage = 0
        do {
            expect(!library.isReady("qwen17-rolling"), "missing library never ready")
            let directory = root.appendingPathComponent("installed/fixture")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stage = 1
            var files: [ModelInstalledFile] = []
            for name in ModelResourceLibrary.requiredFiles("qwen17-rolling").sorted() {
                try bytes.write(to: directory.appendingPathComponent(name))
                files.append(.init(name: name, sha256: hash, bytes: 1))
            }
            do {
                try library.register("qwen17-rolling", directory: directory, version: "fixture", source: "migration", files: Array(files.prefix(1)))
                expect(false, "partial required-file set rejected")
            } catch { expect(!library.isReady("qwen17-rolling"), "partial index stays closed") }
            try library.register("qwen17-rolling", directory: directory, version: "fixture", source: "migration", files: files)
            stage = 2
            expect(library.isReady("qwen17-rolling"), "complete migration presence recognized")
            expect(library.integrityFiles("qwen17-rolling").count == files.count, "health consumes same registered files")
            try library.register("qwen17-rolling", directory: directory, version: "fixture", source: "download", files: files)
            stage = 3
            expect(library.isReady("qwen17-rolling"), "download uses identical readiness contract")
            let weight = directory.appendingPathComponent("model.safetensors")
            let retained = directory.appendingPathComponent("weight-before-link")
            try FileManager.default.moveItem(at: weight, to: retained)
            try FileManager.default.createSymbolicLink(at: weight, withDestinationURL: retained)
            stage = 4
            expect(!library.isReady("qwen17-rolling"), "symlink model rejected")
            try FileManager.default.moveItem(at: weight, to: directory.appendingPathComponent("rejected-link"))
            try bytes.write(to: weight)
            stage = 5
            let index = root.appendingPathComponent("library.json")
            let good = try Data(contentsOf: index)
            try Data("{\"schema_version\":99,\"models\":{}}".utf8).write(to: index)
            expect(!library.isReady("qwen17-rolling"), "unknown schema rejected")
            try Data("{".utf8).write(to: index)
            expect(!library.isReady("qwen17-rolling"), "partial JSON rejected")
            try good.write(to: index)
            stage = 6
            let unsafe = ModelResourceEntry(directory: "../outside", version: "fixture", source: "migration", files: files)
            try JSONEncoder().encode(ModelResourceIndex(models: ["qwen17-rolling": unsafe])).write(to: index)
            expect(!library.isReady("qwen17-rolling"), "outside index rejected")
            do { _ = try library.managedDirectory("qwen17-rolling"); expect(false, "outside deletion rejected") } catch {}
            try good.write(to: index)
            stage = 7
            let beforeFailedWrite = try Data(contentsOf: index)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            do {
                try library.register("qwen17-rolling", directory: directory, version: "replacement", source: "download", files: files)
                expect(false, "failed staging must not publish a replacement")
            } catch {
                expect(try Data(contentsOf: index) == beforeFailedWrite, "failed write preserves previous index bytes")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try library.unregister("qwen17-rolling")
            expect(!library.isReady("qwen17-rolling") && FileManager.default.fileExists(atPath: weight.path), "unregister never removes source files")
        } catch { failures.append("model library synthetic fixture operation failed stage=\(stage) code=\((error as NSError).code)") }
        return failures
    }
}
