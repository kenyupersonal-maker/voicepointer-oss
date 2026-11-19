// T12 2026-10-02: Production cleanup bridge; review hosts inject memory-only VMs instead.
import AppKit
import VoicePointerCore

@MainActor final class SettingsDataRuntime {
    private let service: AppDataManagement
    var beforeRemoval: ((Bool) async throws -> Void)?
    var afterRemoval: (() async -> Void)?
    init() {
        service = AppDataManagement(paths: .init(home: FileManager.default.homeDirectoryForCurrentUser), trash: { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        })
    }
    func inventory() async throws -> AppDataSummary {
        let service = service
        do { return try await Task.detached(priority: .utility) { try service.inspect() }.value }
        catch { throw error as? AppDataFailure ?? .inventory }
    }
    func remove(_ id: ManagedDataID) async throws {
        try await beforeRemoval?(false)
        if id == .touchSamples {
            guard await TouchSampleRecorder.shared.clear() == .idle else { throw AppDataFailure.removal }
            await afterRemoval?()
            return
        }
        let service = service
        do { try await Task.detached(priority: .utility) { try service.remove(id) }.value }
        catch { throw error as? AppDataFailure ?? .removal }
        await afterRemoval?()
    }
    func clearLexicon() async throws {
        try await beforeRemoval?(false)
        CorrectionLearningRuntime.shared.discardForDataRemoval()
        await LexiconRuntime.shared.discardForDataRemoval()
        let service = service
        do { try await Task.detached(priority: .utility) { try service.clearLexicon() }.value }
        catch { throw error as? AppDataFailure ?? .removal }
        try await LexiconRuntime.shared.finishDataRemoval()
    }
    func prepareUninstall() async throws {
        _ = try await inventory() // Refuse malformed index/protected paths before stopping the app.
        guard let beforeRemoval else { throw AppDataFailure.removal }
        try await beforeRemoval(true)
        do { try await LoginItemService.shared.unregisterForUninstall() } catch { throw AppDataFailure.loginItem }
        let service = service
        do { try await Task.detached(priority: .utility) { try service.prepareUninstall() }.value }
        catch { throw error as? AppDataFailure ?? .removal }
        NSApplication.shared.terminate(nil) // Explicitly confirmed operation; App stays for manual Trash/uninstall script.
    }
}
