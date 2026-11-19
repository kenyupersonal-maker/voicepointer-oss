// T10 2026-10-02: Utility-priority, cancellable offline child. It reloads tensors but never performs ASR.
import Foundation

public struct ModelPythonConverter: ModelConverting {
    public let python: URL, script: URL, catalog: URL, sandboxProfile: URL, privateData: URL
    public let applySandbox: Bool
    public init(python: URL, script: URL, catalog: URL, sandboxProfile: URL, privateData: URL, applySandbox: Bool = true) {
        self.python = python; self.script = script; self.catalog = catalog; self.sandboxProfile = sandboxProfile
        self.privateData = privateData; self.applySandbox = applySandbox
    }
    public func convert(source: URL, stage: URL, spec: ModelDownloadSpec) async throws -> ModelConversionReceipt {
        let runner = Runner()
        let operation = Task.detached(priority: .utility) {
            try await withTaskCancellationHandler {
                try await runner.run(python: python, script: script, catalog: catalog, source: source, stage: stage,
                                     id: spec.id.rawValue, sandbox: applySandbox ? sandboxProfile : nil, privateData: privateData)
            } onCancel: { runner.cancel() }
        }
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await operation.value }
                group.addTask { try await Task.sleep(for: .seconds(600)); runner.cancel(); throw ModelDownloadError.conversion }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: { operation.cancel(); runner.cancel() }
        try Task.checkCancellation()
        let receiptURL = stage.appendingPathComponent("conversion-receipt.json")
        guard (try? receiptURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let size = try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000 else { throw ModelDownloadError.reloadFailed }
        do { return try JSONDecoder().decode(ModelConversionReceipt.self, from: Data(contentsOf: receiptURL)) }
        catch { throw ModelDownloadError.reloadFailed }
    }
    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func cancel() {
            lock.lock(); cancelled = true; let process = process; lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func run(python: URL, script: URL, catalog: URL, source: URL, stage: URL, id: String,
                 sandbox: URL?, privateData: URL) async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let child = Process(); child.qualityOfService = .utility
                let arguments = [script.path, "--catalog", catalog.path, "--id", id, "--source", source.path, "--stage", stage.path]
                if let sandbox {
                    child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                    child.arguments = ["-D", "SOURCE=\(source.path)", "-D", "STAGE=\(stage.path)", "-D", "PRIVATE_DATA=\(privateData.path)",
                                       "-f", sandbox.path, python.path] + arguments
                } else { child.executableURL = python; child.arguments = arguments }
                var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
                environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
                environment["PYTHONDONTWRITEBYTECODE"] = "1"
                environment["TMPDIR"] = stage.path; environment["HF_HOME"] = stage.appendingPathComponent(".cache").path
                child.environment = environment
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                child.terminationHandler = { [weak self] process in
                    self?.lock.lock(); let cancelled = self?.cancelled ?? true; self?.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: ModelDownloadError.conversion) }
                }
                lock.lock(); process = child; let stopped = cancelled; lock.unlock()
                if stopped { continuation.resume(throwing: CancellationError()); return }
                do { try child.run() }
                catch { continuation.resume(throwing: ModelDownloadError.conversion); return }
                lock.lock(); let cancelledAfterLaunch = cancelled; lock.unlock()
                if cancelledAfterLaunch { child.terminate() }
            }
        }
    }
}
