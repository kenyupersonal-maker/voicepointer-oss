// T10 2026-10-02: Real downloader/VM with synthetic bytes, fake HTTP and app-owned fixture Trash.
import Foundation
import CryptoKit
import VoicePointerCore

@MainActor enum ModelDownloaderChecks {
    private actor Transport: ModelDownloadTransport {
        enum Mode: Sendable { case normal, noRange, offline, corrupt, fallback, partialCorrupt, paused }
        let data: Data
        let mode: Mode
        var offsets: [UInt64] = []
        var hosts: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        init(_ data: Data, _ mode: Mode = .normal) { self.data = data; self.mode = mode }
        func transfer(url: URL, offset: UInt64, destination: URL, expectedBytes: UInt64,
                      progress: @escaping @Sendable (UInt64) -> Void) async throws {
            offsets.append(offset); hosts.append(url.host ?? "")
            if mode == .paused { await withCheckedContinuation { pending = $0 }; try Task.checkCancellation() }
            let start = try ModelRangePolicy.startingOffset(status: offset > 0 && mode != .noRange ? 206 : 200,
                requested: offset, contentRange: "bytes \(offset)-\(data.count - 1)/\(data.count)")
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: start); try handle.seek(toOffset: start)
            defer { try? handle.close() }
            if mode == .offline || ((mode == .fallback || mode == .partialCorrupt) && url.host == "primary.test") {
                if start == 0 { try handle.write(contentsOf: mode == .partialCorrupt ? Data([0,0,0]) : data.prefix(3)); progress(3) }
                throw ModelDownloadError.offline
            }
            let output = mode == .corrupt ? Data(repeating: 0x77, count: data.count) : data
            try handle.write(contentsOf: output.dropFirst(Int(start))); progress(UInt64(output.count))
        }
        func release() { pending?.resume(); pending = nil }
        func calls() -> Int { offsets.count }
        func receivedOffsets() -> [UInt64] { offsets }
    }
    private final class Manager: LocalModelManaging {
        let downloader: ModelDownloader, spec: ModelDownloadSpec
        init(_ downloader: ModelDownloader, _ spec: ModelDownloadSpec) { self.downloader = downloader; self.spec = spec }
        func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void) async throws {
            _ = try await downloader.download(spec, consent: true) { value in Task { @MainActor in progress(value) } }
        }
        func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void,
                      stage: @escaping @MainActor (ModelDownloadStage) -> Void) async throws {
            _ = try await downloader.download(spec, consent: true, progress: { value in Task { @MainActor in progress(value) } },
                stage: { value in Task { @MainActor in stage(value) } })
        }
        func cancel(_ id: LocalModelID) {}
        func moveToTrash(_ id: LocalModelID) async throws { try await downloader.moveToTrash(spec) }
        func use(_ id: LocalModelID) async throws {}
    }
    private actor Converter: ModelConverting {
        enum Mode: Sendable { case good, badShape, badSHA, interrupted, paused }
        let mode: Mode
        var calls = 0
        var pending: CheckedContinuation<Void, Never>?
        init(_ mode: Mode = .good) { self.mode = mode }
        func convert(source: URL, stage: URL, spec: ModelDownloadSpec) async throws -> ModelConversionReceipt {
            calls += 1
            if mode == .paused { await withCheckedContinuation { pending = $0 } } // Deliberately late: downloader must discard it.
            if mode == .interrupted {
                try Data([1,2]).write(to: stage.appendingPathComponent("incomplete")); throw ModelDownloadError.conversion
            }
            let weight = Data("synthetic-quantized-model".utf8)
            let files: [String: Data] = ["model.safetensors": weight, "config.json": Data("{}".utf8),
                "tokenizer_config.json": Data("{}".utf8), "preprocessor_config.json": Data("{}".utf8),
                "chat_template.json": Data("{}".utf8), "LICENSE": Data("synthetic-license".utf8),
                "quantization_config.json": Data("{\"bits\":8,\"group_size\":64,\"scope\":\"all_supported_layers\"}".utf8)]
            var metadata: [ModelInstalledFile] = []
            for (name, data) in files {
                try data.write(to: stage.appendingPathComponent(name))
                metadata.append(.init(name: name, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: UInt64(data.count)))
            }
            if mode == .badSHA { try Data(repeating: 0, count: weight.count).write(to: stage.appendingPathComponent("model.safetensors")) }
            let receipt = ModelConversionReceipt(sourceVersion: spec.version, parameterCount: 3, quantizedLayers: 1,
                reloadVerified: mode != .badShape, files: metadata)
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("conversion-receipt.json"))
            return receipt
        }
        func count() -> Int { calls }
        func release() { pending?.resume(); pending = nil }
    }
    private static func flush() async { for _ in 0..<100 { await Task.yield() } }
    static func run() async -> [String] {
        var failures: [String] = []
        var checks = 0, checkpoint = 0
        func expect(_ value: Bool, _ name: String) { checks += 1; if !value { failures.append("T10 model: " + name) } }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".cache/t10-download-fixtures/\(UUID().uuidString)")
        let data = Data("synthetic-model-container".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let spec = ModelDownloadSpec(id: .qwen06, version: "fixture-v1", files: [
            .init(name: "model.safetensors", bytes: UInt64(data.count), sha256: sha,
                urls: [URL(string: "https://primary.test/model")!, URL(string: "https://fallback.test/model")!])])
        func loader(_ name: String, _ transport: Transport, disk: UInt64 = UInt64.max, converter: (any ModelConverting)? = nil) -> ModelDownloader {
            let root = fixture.appendingPathComponent(name)
            return ModelDownloader(root: root, transport: transport, converter: converter, freeBytes: { disk }, trash: { url in
                let trash = root.appendingPathComponent("Trash/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trash)
            })
        }
        do {
            checkpoint = 1
            let transport = Transport(data), downloader = loader("consent", transport)
            do { _ = try await downloader.download(spec, consent: false) { _ in }; expect(false, "consent refused") }
            catch { expect(error as? ModelDownloadError == .consentRequired, "consent reason") }
            expect(await transport.calls() == 0, "zero calls before consent")
            let url = try await downloader.download(spec, consent: true) { _ in }
            expect(try Data(contentsOf: url.appendingPathComponent("model.safetensors")) == data, "verified atomic activation bytes")
            _ = try await downloader.download(spec, consent: true) { _ in }
            expect(await transport.calls() == 1, "ready repeat is idempotent")
            try await downloader.moveToTrash(spec)
            expect(!FileManager.default.fileExists(atPath: url.path), "only library moved to fixture Trash")
            _ = try await downloader.download(spec, consent: true) { _ in }
            expect(await transport.calls() == 2, "delete then redownload")
            checkpoint = 2
            let offline = Transport(data, .offline), interrupted = loader("restart", offline)
            do { _ = try await interrupted.download(spec, consent: true) { _ in }; expect(false, "interruption fails") }
            catch { expect(error as? ModelDownloadError == .offline, "interruption status") }
            let resumed = Transport(data), restarted = loader("restart", resumed)
            _ = try await restarted.download(spec, consent: true) { _ in }
            expect(await resumed.receivedOffsets() == [3], "new instance resumes on-disk partial")
            checkpoint = 3
            let interrupted2 = loader("noRange", Transport(data, .offline))
            do { _ = try await interrupted2.download(spec, consent: true) { _ in } } catch {}
            let noRange = Transport(data, .noRange)
            let replaced = try await loader("noRange", noRange).download(spec, consent: true) { _ in }
            expect(try Data(contentsOf: replaced.appendingPathComponent("model.safetensors")) == data, "200 replaces partial")
            expect(await noRange.receivedOffsets() == [3], "Range attempted before 200 fallback")
            do { _ = try ModelRangePolicy.startingOffset(status: 206, requested: 3, contentRange: "bytes 0-8/9"); expect(false, "wrong range denied") } catch {}

            let fallback = Transport(data, .fallback)
            _ = try await loader("fallback", fallback).download(spec, consent: true) { _ in }
            expect(await fallback.receivedOffsets() == [0, 3], "primary failure resumes from backup")
            let corruptPrefix = Transport(data, .partialCorrupt)
            _ = try await loader("corrupt-prefix", corruptPrefix).download(spec, consent: true) { _ in }
            expect(await corruptPrefix.receivedOffsets() == [0,3,0], "backup retries corrupt resumed prefix from zero")
            checkpoint = 4
            let disk = Transport(data)
            do { _ = try await loader("disk", disk, disk: 0).download(spec, consent: true) { _ in }; expect(false, "disk refusal") }
            catch { expect(error as? ModelDownloadError == .diskFull, "disk reason") }
            expect(await disk.calls() == 0, "disk check before transport")
            let badLoader = loader("bad", Transport(data, .corrupt))
            do { _ = try await badLoader.download(spec, consent: true) { _ in }; expect(false, "checksum refusal") }
            catch { expect(error as? ModelDownloadError == .checksum, "checksum reason") }
            let badURL = try await badLoader.installedURL(spec)
            expect(!FileManager.default.fileExists(atPath: badURL.path), "corrupt never activates")

            let paused = Transport(data, .paused), queued = loader("cancel", paused)
            let task = Task { try await queued.download(spec, consent: true) { _ in } }
            while await paused.calls() == 0 { await Task.yield() }
            do { _ = try await queued.download(spec, consent: true) { _ in }; expect(false, "duplicate refused") }
            catch { expect(error as? ModelDownloadError == .busy, "duplicate status") }
            task.cancel(); await paused.release()
            do { _ = try await task.value; expect(false, "cancel prevents activation") } catch is CancellationError {} catch { expect(false, "cancel status") }
            expect(await paused.calls() == 1, "duplicate and cancel no new request")
            checkpoint = 5
            let vmTransport = Transport(data, .paused), vmLoader = loader("vm", vmTransport)
            let hardware = SettingsHardwareInfo(memoryBytes: 32 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true)
            let vm = LocalModelInstallerViewModel(hardware: hardware, manager: Manager(vmLoader, spec))
            vm.update(models: [.init(id: .qwen06, sizeBytes: UInt64(data.count), recommended: true, state: .notDownloaded)])
            vm.perform(.download, id: .qwen06); await flush()
            expect(await vmTransport.calls() == 0 && vm.downloadError == .consentRequired, "VM consent data flow")
            vm.perform(.download, id: .qwen06, consent: true)
            while await vmTransport.calls() == 0 { await Task.yield() }
            vm.perform(.download, id: .qwen06, consent: true); vm.cancelDownloads(); await vmTransport.release(); await flush()
            expect(await vmTransport.calls() == 1 && vm.models.first?.state == .notDownloaded, "VM route-close cancels late completion")
            checkpoint = 6
            let raw = ModelDownloadSpec(id: .qwen17, version: "raw-to-8bit-v1", files: spec.files,
                conversion: .init(outputEstimateBytes: 100, diskReserveBytes: 100))
            let oldActive = fixture.appendingPathComponent("legacy-active/model.safetensors")
            try FileManager.default.createDirectory(at: oldActive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: oldActive)
            for mode in [Converter.Mode.badShape, .badSHA, .interrupted] {
                let convert = Converter(mode), transport = Transport(data)
                let download = loader("converted-\(mode)", transport, converter: convert)
                do { _ = try await download.download(raw, consent: true) { _ in }; expect(false, "bad conversion refused") } catch {}
                let active = try await download.installedURL(raw)
                expect(!FileManager.default.fileExists(atPath: active.path), "unverified output never publishes")
                expect(try Data(contentsOf: oldActive) == data, "conversion failure preserves old active bytes")
            }
            let interruptedConverter = Converter(.interrupted), conversionTransport = Transport(data)
            let interruptedDownload = loader("conversion-restart", conversionTransport, converter: interruptedConverter)
            do { _ = try await interruptedDownload.download(raw, consent: true) { _ in } } catch {}
            let goodConverter = Converter()
            let restartedConversion = loader("conversion-restart", conversionTransport, converter: goodConverter)
            let convertedURL = try await restartedConversion.download(raw, consent: true) { _ in }
            var networkCount = await conversionTransport.calls(), conversionCount = await goodConverter.count()
            expect(networkCount == 1 && conversionCount == 1, "restart reuses verified raw source")
            expect(try Data(contentsOf: convertedURL.appendingPathComponent("model.safetensors")) != data, "raw weight is never directly activated")
            let installed = try await restartedConversion.hasInstalledFiles(raw)
            expect(installed, "converted receipt persists for restart inventory")
            _ = try await restartedConversion.download(raw, consent: true) { _ in }
            networkCount = await conversionTransport.calls(); conversionCount = await goodConverter.count()
            expect(networkCount == 1 && conversionCount == 1, "verified conversion is idempotent")
            try await restartedConversion.moveToTrash(raw)
            _ = try await restartedConversion.download(raw, consent: true) { _ in }
            networkCount = await conversionTransport.calls(); conversionCount = await goodConverter.count()
            expect(networkCount == 2 && conversionCount == 2, "delete raw and output then re-download/reconvert")
            let conversionDisk = Transport(data)
            do { _ = try await loader("conversion-disk", conversionDisk, disk: raw.requiredSpaceBytes - 1, converter: Converter()).download(raw, consent: true) { _ in }; expect(false, "full peak space required") } catch {}
            expect(await conversionDisk.calls() == 0, "raw plus output plus reserve checked before request")
            let late = Converter(.paused), lateTransport = Transport(data)
            let lateLoader = loader("conversion-cancel", lateTransport, converter: late)
            let lateTask = Task { try await lateLoader.download(raw, consent: true) { _ in } }
            while await late.count() == 0 { await Task.yield() }
            lateTask.cancel(); await late.release()
            do { _ = try await lateTask.value; expect(false, "late conversion cancelled") } catch is CancellationError {} catch { expect(false, "conversion cancel status") }
            let lateURL = try await lateLoader.installedURL(raw)
            let oldBytes = try Data(contentsOf: oldActive)
            expect(!FileManager.default.fileExists(atPath: lateURL.path) && oldBytes == data, "late conversion cannot replace active")
            // The real utility child adapter is cancelled with a stand-in Python process, no model/GPU/network.
            let processStage = fixture.appendingPathComponent("child-cancel")
            try FileManager.default.createDirectory(at: processStage, withIntermediateDirectories: true)
            let fakeScript = fixture.appendingPathComponent("child.py")
            try Data("from pathlib import Path\nimport sys,time\nstage=Path(sys.argv[sys.argv.index('--stage')+1])\n(stage/'started').write_bytes(b'1')\ntime.sleep(5)\n(stage/'late').write_bytes(b'1')\n".utf8).write(to: fakeScript)
            let processConverter = ModelPythonConverter(python: URL(fileURLWithPath: "/usr/bin/python3"), script: fakeScript,
                catalog: fakeScript, sandboxProfile: fakeScript, privateData: fixture, applySandbox: false)
            let processTask = Task { try await processConverter.convert(source: fixture, stage: processStage, spec: raw) }
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: processStage.appendingPathComponent("started").path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(FileManager.default.fileExists(atPath: processStage.appendingPathComponent("started").path), "stand-in child started")
            processTask.cancel()
            do { _ = try await processTask.value; expect(false, "stand-in child cancellation") } catch is CancellationError {} catch { expect(false, "stand-in child cancellation status") }
            expect(!FileManager.default.fileExists(atPath: processStage.appendingPathComponent("late").path), "cancel terminates child before late write")
            checkpoint = 7
            for gb in [8,16,32] {
                let hw = SettingsHardwareInfo(memoryBytes: UInt64(gb) << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true)
                expect(hw.supports(.qwen06) && hw.supports(.qwen17) == (gb >= 16), "hardware boundary")
                expect(ModelHardwarePolicy().recommended(on: hw) == (gb == 8 ? .qwen06 : .qwen17), "hardware recommendation")
            }
            var policy = ModelHardwarePolicy(); policy.model17MinimumBytes = 64 << 30
            expect(!hardware.supports(.qwen17, policy: policy), "config changes threshold")
            for path in [OnboardingPath.doubao, .local, .online] {
                let store = try OnboardingProgressStore(dataRoot: fixture.appendingPathComponent("wizard-\(path.rawValue)"))
                try store.begin(); expect(store.progress.step == .initialPermissions, "permissions first")
                try store.permissionsSatisfied(accessibility: true, inputMonitoring: true, microphone: true)
                try store.choose(path: path)
                switch path {
                case .doubao: expect(store.progress.step == .doubaoCheckInstallation, "Doubao branch"); try store.advance(to: .doubaoPractice)
                case .local: expect(store.progress.step == .localPrepareModel, "local branch"); try store.selectLocalRoute(LocalModelID.qwen06.rawValue); try store.advance(to: .localPractice)
                case .online:
                    expect(store.progress.step == .onlineConfiguration, "API branch")
                    do { try store.onlineConfigured(selectable: false); expect(false, "API admission required") } catch {}
                    try store.onlineConfigured(selectable: true)
                }
                try store.complete(); expect(store.progress.isCompleted, "branch completes")
            }
            for legacy in [OnboardingStep.localCloudConfiguration, .doubaoPermissions, .localPermissions] {
                let store = try OnboardingProgressStore(dataRoot: fixture.appendingPathComponent("legacy-\(legacy.rawValue)"))
                let path: OnboardingPath = legacy == .doubaoPermissions ? .doubao : .local
                try store.start(path: path); try store.advance(to: legacy)
                try store.advanceLegacyCheckpoint(permissionsSatisfied: true)
                expect(store.progress.step == (path == .doubao ? .doubaoPractice : .localPractice), "legacy skips \(legacy.rawValue)")
            }
            expect(CompletionDeviceSelection.resolve(kinds: [.builtInTrackpad]) == .trackpad, "completion trackpad")
            expect(CompletionDeviceSelection.resolve(kinds: [.magicMouse]) == .mouse, "completion mouse")
            expect(CompletionDeviceSelection.resolve(kinds: [.magicMouse, .externalTrackpad]) == .both, "completion both")
        } catch {
            failures.append("T10 model: fixture operation failed at \(checkpoint)")
            let reason = (error as? ModelDownloadError)?.rawValue ?? "io"
            let line = "event=model_download_fixture_error,stage=\(checkpoint),code=\((error as NSError).code),reason=\(reason)"
            assert(reason == "io" || ModelDownloadError(rawValue: reason) != nil)
            print(line)
        }
        let line = ModelDownloadDiagnostics.line(cases: checks, passed: failures.isEmpty)
        expect(ModelDownloadDiagnostics.isWhitelisted(line) && !ModelDownloadDiagnostics.isWhitelisted(line + ",text=forbidden"), "log whitelist")
        print(line)
        return failures
    }
}
