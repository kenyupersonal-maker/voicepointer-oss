// T12: Production service and VM tests, using synthetic homes under .cache and injected Trash only.
import Foundation
@_spi(Testing) import VoicePointerCore

@MainActor enum AppDataManagementChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        var cases = 0
        func expect(_ value: Bool, _ name: String) { cases += 1; if !value { failures.append("T12 data: " + name) } }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/maintenance04-build/data-swift-" + UUID().uuidString)
        let paths = AppDataPaths(home: root)
        let fm = FileManager.default
        func write(_ url: URL, _ data: Data = Data("synthetic-opaque-not-json".utf8)) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let trash: AppDataManagement.Trash = { url in
            let trash = root.appendingPathComponent(".Trash")
            try AppDataManagement.validate(trash, inside: root)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString))
        }
        let service = AppDataManagement(paths: paths, trash: trash)
        do {
            try write(paths.preferences)
            try write(paths.data.appendingPathComponent("provider-settings.json"))
            try write(paths.data.appendingPathComponent("Lexicon/lexicon.json"))
            try write(paths.cache.appendingPathComponent("runtime.log"))
            try write(paths.loginItem)
            let outside = root.appendingPathComponent("Documents/untouched")
            let keep = root.appendingPathComponent("keep-0.5.50/untouched")
            let old = root.appendingPathComponent("dist/integrated-preview/integrated-trial-04.app/untouched")
            for url in [outside, keep, old] { try write(url) }
            let library = ModelResourceLibrary(root: paths.data.appendingPathComponent("Models"))
            var files: [ModelInstalledFile] = []
            let model = library.root.appendingPathComponent("installed/synthetic-qwen06")
            for name in ModelResourceLibrary.requiredFiles("qwen06-rolling").sorted() {
                try write(model.appendingPathComponent(name), Data([1, 2, 3]))
                files.append(.init(name: name, sha256: String(repeating: "a", count: 64), bytes: 3))
            }
            try library.register("qwen06-rolling", directory: model, version: "synthetic", source: "migration", files: files)
            try write(library.root.appendingPathComponent("partial/synthetic/partial.bin"), Data([4, 5]))
            let initial = try service.inspect()
            expect(initial.items.first { $0.id == .model06 }?.sizeBytes == UInt64(files.count * 3), "real metadata model size")
            expect(initial.items.contains { $0.id == .modelDownloads && $0.sizeBytes == 2 }, "partial downloads enumerated")
            expect(initial.totalBytes > initial.items.reduce(0) { $0 + $1.sizeBytes }, "total includes opaque preferences and lexicon")
            var changes = 0, requests = 0, clears = 0
            let vm = DataManagementViewModel(inventory: { try service.inspect() },
                deleteItem: { try service.remove($0) }, clearLexicon: { clears += 1; try service.clearLexicon() },
                prepareUninstall: { requests += 1; try service.prepareUninstall() })
            vm.onChange = { changes += 1 }
            expect(vm.phase == .idle, "idle before metadata refresh")
            await vm.refresh(); expect(vm.items == initial.items && vm.totalBytes == initial.totalBytes, "VM consumes production inventory")
            await vm.confirmUninstall(); expect(requests == 0, "no first intent means no cleanup")
            vm.requestUninstall(); vm.cancelUninstall(); await vm.confirmUninstall()
            expect(requests == 0 && fm.fileExists(atPath: paths.data.path), "cancel preserves real fixture tree")
            await vm.delete(.model06)
            let afterDeleteIndex = try library.index()
            expect(!fm.fileExists(atPath: model.path) && afterDeleteIndex.models.isEmpty, "per-item Trash updates single index")
            expect(vm.phase == .content && !vm.items.contains { $0.id == .model06 }, "VM deletion re-enumerates")
            await vm.clearLexicon()
            expect(clears == 1 && !fm.fileExists(atPath: paths.data.appendingPathComponent("Lexicon").path), "clear removes own lexicon opaquely")
            // Invalid schema is reported, never presented as a successful empty state.
            let index = library.root.appendingPathComponent("library.json")
            try write(index, Data("{\"schema_version\":99,\"models\":{}}".utf8))
            await vm.refresh(); expect(vm.phase == .error && vm.failure != nil, "invalid schema surfaces error")
            try write(index, JSONEncoder().encode(ModelResourceIndex()))
            await vm.refresh(); expect(vm.phase == .content, "valid schema1 reload recovers")
            let linked = paths.data.appendingPathComponent("linked")
            try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
            do { _ = try service.inspect(); expect(false, "symlink must reject") } catch { expect(true, "symlink reject") }
            // Move the synthetic link itself aside without following it; never delete an actual user path.
            try fm.moveItem(at: linked, to: root.appendingPathComponent("rejected-link"))
            let protected = paths.data.appendingPathComponent("keep-0.5.50/untouched")
            try write(protected)
            vm.requestUninstall(); await vm.confirmUninstall()
            expect(vm.phase == .error && vm.confirmation == .none && fm.fileExists(atPath: protected.path), "protected child fails without partial cleanup")
            try fm.moveItem(at: protected.deletingLastPathComponent(), to: root.appendingPathComponent("preserved-fixture"))
            vm.requestUninstall(); await vm.confirmUninstall()
            expect(vm.phase == .empty && vm.items.isEmpty && vm.totalBytes == 0 && vm.confirmation == .confirmed, "confirmed production cleanup completes")
            let completedRequests = requests
            await vm.confirmUninstall(); vm.requestUninstall(); await vm.confirmUninstall()
            expect(requests == completedRequests, "completed operation cannot repeat")
            expect(paths.removalTargets.allSatisfy { !fm.fileExists(atPath: $0.path) }, "all own targets moved")
            expect([outside, keep, old].allSatisfy { fm.fileExists(atPath: $0.path) }, "outside and protected targets untouched")
            let snapshots = try fm.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
            expect(snapshots.count == 1, "single opaque snapshot")
            expect(try AppDataManagement.bytes(snapshots[0], inside: root) < 50_000_000, "snapshot below decimal limit")
            expect(try Data(contentsOf: snapshots[0].appendingPathComponent(AppDataPaths.bundleID + ".plist")) == Data("synthetic-opaque-not-json".utf8), "preference bytes preserved without decoding")
            expect(!fm.fileExists(atPath: snapshots[0].appendingPathComponent("ApplicationSupport-" + AppDataPaths.bundleID + "/Models").path), "models excluded from snapshot")
            expect(changes > 5, "loading/result/error state changes notify")
            let touchPaths = AppDataPaths(home: root.appendingPathComponent("touch-home"))
            let touchService = AppDataManagement(paths: touchPaths, trash: trash)
            try write(touchPaths.touchSamples[0], Data([1, 2, 3]))
            try write(touchPaths.touchSamples[1], Data([4, 5]))
            try write(touchPaths.cache.appendingPathComponent("runtime.log"), Data([6]))
            let touchInventory = try touchService.inspect()
            expect(touchInventory.items.first { $0.id == .touchSamples }?.sizeBytes == 5, "touch sampling files explicit inventory item")
            expect(touchInventory.items.first { $0.id == .diagnosticLogs }?.sizeBytes == 1, "diagnostic bytes exclude touch samples")
            try touchService.remove(.diagnosticLogs)
            expect(touchPaths.touchSamples.allSatisfy { fm.fileExists(atPath: $0.path) }, "diagnostic deletion preserves touch records")
            try touchService.remove(.touchSamples)
            expect(touchPaths.touchSamples.allSatisfy { !fm.fileExists(atPath: $0.path) }, "explicit touch files both go to fake Trash")
            expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: outside.path), "touch removal does not change protected outside paths")
            // Revocation drains delayed hit writers, without reading private contents during cleanup.
            let storeRoot = root.appendingPathComponent("store-fixture")
            let store = LexiconStore(directory: storeRoot, hitFlushDelay: 0.01)
            _ = try await store.load()
            let term = try await store.add(canonical: "合成词", variants: ["合成误词"], source: .manual)
            await store.recordHits([term.term.id: 1])
            await store.discardForDataRemoval()
            try fm.moveItem(at: storeRoot, to: root.appendingPathComponent("store-trash"))
            try await store.flush()
            let discardedTerms = await store.allTerms()
            expect(!fm.fileExists(atPath: storeRoot.path) && discardedTerms.isEmpty, "late lexicon flush cannot recreate removed data")
            try await store.finishDataRemoval()
            _ = try await store.add(canonical: "新合成词", variants: [], source: .manual)
            expect(fm.fileExists(atPath: storeRoot.path), "future explicit add works with empty store")
            // Close the log handle and fence late lifecycle records before cache Trash.
            let log = root.appendingPathComponent("trace-fixture/runtime.log")
            RuntimeTrace.configureForTesting(fileURL: log)
            RuntimeTrace.record("event=data_test,status=before"); RuntimeTrace.suspendForDataRemoval()
            try fm.moveItem(at: log.deletingLastPathComponent(), to: root.appendingPathComponent("trace-trash"))
            RuntimeTrace.record("event=data_test,status=late"); RuntimeTrace.flush()
            expect(!fm.fileExists(atPath: log.path), "late log cannot recreate removed cache")
            RuntimeTrace.resetTestingConfiguration()
            for byteCount in [UInt64(48_999_999), 49_000_000, 49_999_999, 50_000_000, 50_000_001] {
                let capPaths = AppDataPaths(home: root.appendingPathComponent("caps/" + String(byteCount)))
                let file = capPaths.data.appendingPathComponent("opaque-boundary")
                try write(file, Data())
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: byteCount); try handle.close()
                let capService = AppDataManagement(paths: capPaths, trash: { _ in })
                if byteCount == 48_999_999 {
                    let snapshot = try capService.snapshot()
                    expect(try AppDataManagement.bytes(snapshot, inside: capPaths.home) < 50_000_000, "decimal snapshot below 50 MB")
                } else {
                    do { _ = try capService.snapshot(); expect(false, "decimal over-cap must reject") }
                    catch AppDataFailure.snapshotTooLarge { expect(!fm.fileExists(atPath: capPaths.backups.path), "decimal rejection leaves targets intact") }
                }
            }
        } catch { failures.append("T12 data: synthetic service execution failed") }
        for phase in SettingsLoadState.allCases {
            let fixture = SettingsViewModelFixtures.Set(phase: phase).data
            expect(fixture.phase == phase, "four-state data fixture")
        }
        // Real VM action failure must be visible to the Form; never suppress it.
        let failing = DataManagementViewModel(inventory: { throw AppDataFailure.inventory },
            deleteItem: { _ in throw AppDataFailure.removal }, clearLexicon: { throw AppDataFailure.removal })
        await failing.refresh(); expect(failing.phase == .error && failing.failure == .inventory, "inventory failure typed")
        failing.update([.init(id: .model17, sizeBytes: 3)])
        await failing.delete(.model17); expect(failing.phase == .error && failing.items.count == 1, "failed item stays visible")
        await failing.clearLexicon(); expect(failing.phase == .error && failing.failure == .removal, "clear failure visible")
        let own = AppDataProcessGuard.Identity(pid: 12, bundleID: AppDataPaths.bundleID,
            bundlePath: "/Applications/VoicePointer.app", executablePath: "/Applications/VoicePointer.app/Contents/MacOS/VoicePointerPreview")
        let other = AppDataProcessGuard.Identity(pid: 13, bundleID: "other.app",
            bundlePath: "/Applications/Other.app", executablePath: "/Applications/Other.app/Contents/MacOS/Other")
        let preview = AppDataProcessGuard.Identity(pid: 14, bundleID: AppDataPaths.bundleID,
            bundlePath: "/synthetic/preview.app", executablePath: "/synthetic/preview.app/Contents/MacOS/VoicePointerPreview")
        expect(!AppDataProcessGuard.mayUninstall([own, other], helperPID: 99), "live exact own app refuses Trash")
        expect(AppDataProcessGuard.mayUninstall([own, other], helperPID: 12), "helper ignores only its own PID")
        expect(AppDataProcessGuard.mayUninstall([other, preview], helperPID: 99), "other process paths unchanged")
        expect(AppDataProcessGuard.mayUninstall([], helperPID: 99), "complete process exit passes fence")
        let line = "event=data_management_checks,status=\(failures.isEmpty ? "passed" : "failed"),cases=\(cases),synthetic_home=1,real_cleanup=0"
        expect(line.range(of: "^[A-Za-z0-9_.=:,-]+$", options: .regularExpression) != nil, "log character whitelist")
        print(line)
        return failures
    }
}
