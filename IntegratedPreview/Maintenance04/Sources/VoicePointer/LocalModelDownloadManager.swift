// T11: Production downloads and migration share the external Models resource index.
import Foundation
import VoicePointerCore

@MainActor final class LocalModelDownloadManager: LocalModelManaging {
    private let catalog: ModelDownloadCatalog?
    private let downloader: ModelDownloader
    private let library = ModelResourceLibrary.current
    init() {
        let root = IntegratedRuntimePaths.modelsRoot
        let resources = Bundle.main.resourceURL?.appendingPathComponent("ModelDownloads")
        catalog = resources.flatMap { try? ModelDownloadCatalog.read($0.appendingPathComponent("catalog.json")) }
        let converter: ModelPythonConverter?
        if let resources, let assets = IntegratedRuntimePaths.assetRoot {
            converter = ModelPythonConverter(python: assets.appendingPathComponent(".cache/venvs/voicenative-beta/bin/python"),
                script: resources.appendingPathComponent("convert-model.py"), catalog: resources.appendingPathComponent("catalog.json"),
                sandboxProfile: resources.appendingPathComponent("model-convert.sb"), privateData: IntegratedRuntimePaths.dataRoot)
        } else { converter = nil }
        downloader = ModelDownloader(root: root, converter: converter, freeBytes: {
            let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let free = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            return UInt64(max(0, free))
        }, trash: { url in
            // Core confines every requested URL to this app-owned Models directory.
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        })
    }
    func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void) async throws {
        try await download(id, progress: progress, stage: { _ in })
    }
    func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void,
                  stage: @escaping @MainActor (ModelDownloadStage) -> Void) async throws {
        guard let spec = catalog?.models.first(where: { $0.id == id }) else { throw ModelDownloadError.sourceUnavailable }
        let prior = library.entry(id.rawValue)
        let priorDirectory = try library.managedDirectory(id.rawValue)
        _ = try await downloader.download(spec, consent: true, progress: { value in Task { @MainActor in progress(value) } },
                                          stage: { value in Task { @MainActor in stage(value) } })
        try Task.checkCancellation()
        let (directory, files) = try await downloader.installedRecord(spec)
        try Task.checkCancellation()
        try library.register(id.rawValue, directory: directory, version: spec.version, source: "download", files: files)
        // The newly verified copy replaces the migrated bundled copy. Only an
        // obsolete app-owned model directory is moved to Trash, never the App.
        if prior?.source == "migration", let priorDirectory, priorDirectory != directory,
           FileManager.default.fileExists(atPath: priorDirectory.path) {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: priorDirectory, resultingItemURL: &resulting)
        }
    }
    func cancel(_ id: LocalModelID) {} // The VM cancels the owning Task, including its URLSession transfer.
    func inventory(_ bundled: [LocalModelItem], hardware: SettingsHardwareInfo) async -> [LocalModelItem] {
        var result = bundled
        for i in result.indices {
            guard let spec = catalog?.models.first(where: { $0.id == result[i].id }) else { continue }
            result[i].downloadBytes = spec.totalBytes
            result[i].conversionOutputBytes = spec.conversion?.outputEstimateBytes
            result[i].requiredSpaceBytes = spec.requiredSpaceBytes
            result[i].libraryInstalled = library.isReady(result[i].id.rawValue)
            let original = await originalDownloadInfo(result[i].id)
            result[i].originalDownloadBytes = original.bytes
            result[i].offersOriginalRemoval = original.offer
            if result[i].sizeBytes == 0 { result[i].sizeBytes = spec.totalBytes }
            if result[i].state == .notDownloaded {
                if result[i].libraryInstalled { result[i].state = .needsVerification }
                else if !hardware.supports(result[i].id, downloadBytes: spec.requiredSpaceBytes - (512 << 20)) { result[i].state = .notApplicable(reason: .hardwareUnsuitable) }
            }
        }
        return result
    }
    func stateAfterAction(_ id: LocalModelID, action: LocalModelAction) -> LocalModelState? {
        nil
    }
    func moveToTrash(_ id: LocalModelID) async throws {
        guard !(SettingsLogicRuntime.shared.selection.mode == .voiceNative && SettingsLogicRuntime.shared.selection.routeID == id.rawValue) else { throw ModelDownloadError.busy }
        guard let spec = catalog?.models.first(where: { $0.id == id }) else { throw ModelDownloadError.sourceUnavailable }
        try await downloader.moveToTrash(spec)
        if let directory = try library.managedDirectory(id.rawValue), FileManager.default.fileExists(atPath: directory.path) {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: directory, resultingItemURL: &resulting)
        }
        try library.unregister(id.rawValue)
    }
    func use(_ id: LocalModelID) async throws {
        guard VoiceNativeModelPreparation.isLocalPrepared(routeID: id.rawValue, language: "auto") else { throw ModelDownloadError.sourceUnavailable }
    }
    func installedModelBytes(_ id: LocalModelID) -> UInt64? { library.entry(id.rawValue)?.files.reduce(UInt64(0)) { $0 + $1.bytes } }
    private func originalChoiceKey(_ spec: ModelDownloadSpec) -> String { "model.original.kept." + spec.id.rawValue + "." + spec.version }
    func originalDownloadInfo(_ id: LocalModelID) async -> (bytes: UInt64?, offer: Bool) {
        guard let spec = catalog?.models.first(where: { $0.id == id }), library.isReady(id.rawValue),
              let bytes = try? await downloader.originalDownloadBytes(spec) else { return (nil, false) }
        return (bytes, !UserDefaults.standard.bool(forKey: originalChoiceKey(spec)))
    }
    func removeOriginalDownload(_ id: LocalModelID) async throws {
        guard let spec = catalog?.models.first(where: { $0.id == id }) else { throw ModelDownloadError.sourceUnavailable }
        try await downloader.moveOriginalToTrash(spec)
        UserDefaults.standard.removeObject(forKey: originalChoiceKey(spec))
    }
    func keepOriginalDownload(_ id: LocalModelID) {
        guard let spec = catalog?.models.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(true, forKey: originalChoiceKey(spec))
    }
}
