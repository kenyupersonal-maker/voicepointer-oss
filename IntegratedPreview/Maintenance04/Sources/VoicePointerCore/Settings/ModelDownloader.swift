// T10 2026-10-02: Verified public files only. Staging is resumable; activation is one directory rename.
import Foundation
import CryptoKit
import Darwin

public enum ModelDownloadDiagnostics {
    public static func line(cases: Int, passed: Bool) -> String {
        "event=model_download_probe,cases=\(cases),network=0,audio_files=0,passed=\(passed ? 1 : 0)"
    }
    public static func isWhitelisted(_ line: String) -> Bool {
        let pairs = line.split(separator: ",").map { $0.split(separator: "=", omittingEmptySubsequences: false) }
        guard pairs.count == 5, pairs.allSatisfy({ $0.count == 2 }),
              Set(pairs.map { String($0[0]) }) == ["event", "cases", "network", "audio_files", "passed"] else { return false }
        let fields = Dictionary(uniqueKeysWithValues: pairs.map { (String($0[0]), String($0[1])) })
        return fields["event"] == "model_download_probe" && fields["network"] == "0" && fields["audio_files"] == "0"
            && ["0", "1"].contains(fields["passed"] ?? "") && UInt(fields["cases"] ?? "") != nil
    }
}

public enum ModelDownloadError: String, Error, Sendable {
    case consentRequired, sourceUnavailable, busy, diskFull, offline, certificate, proxy, checksum, http, unsafePath, io
    case conversion, reloadFailed
}
public enum ModelDownloadStage: String, Sendable { case downloading, converting, verifying }
public struct ModelConversionPlan: Codable, Sendable {
    public let bits: Int, groupSize: Int
    public let runtimeVersion: String
    public let outputEstimateBytes: UInt64, diskReserveBytes: UInt64
    public init(bits: Int = 8, groupSize: Int = 64, runtimeVersion: String = "0.4.0", outputEstimateBytes: UInt64, diskReserveBytes: UInt64 = 1 << 30) {
        self.bits = bits; self.groupSize = groupSize; self.runtimeVersion = runtimeVersion
        self.outputEstimateBytes = outputEstimateBytes; self.diskReserveBytes = diskReserveBytes
    }
}
public struct ModelInstalledFile: Codable, Sendable {
    public let name: String, sha256: String
    public let bytes: UInt64
    public init(name: String, sha256: String, bytes: UInt64) { self.name = name; self.sha256 = sha256; self.bytes = bytes }
}
public struct ModelConversionReceipt: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceVersion: String, runtimeVersion: String, dtype: String
    public let bits: Int, groupSize: Int, parameterCount: Int, quantizedLayers: Int
    public let reloadVerified: Bool
    public let files: [ModelInstalledFile]
    public init(sourceVersion: String, runtimeVersion: String = "0.4.0", dtype: String = "float16", bits: Int = 8,
                groupSize: Int = 64, parameterCount: Int, quantizedLayers: Int, reloadVerified: Bool, files: [ModelInstalledFile]) {
        schemaVersion = 1; self.sourceVersion = sourceVersion; self.runtimeVersion = runtimeVersion; self.dtype = dtype
        self.bits = bits; self.groupSize = groupSize; self.parameterCount = parameterCount; self.quantizedLayers = quantizedLayers
        self.reloadVerified = reloadVerified; self.files = files
    }
}
public protocol ModelConverting: Sendable {
    func convert(source: URL, stage: URL, spec: ModelDownloadSpec) async throws -> ModelConversionReceipt
}
public struct ModelDownloadFile: Codable, Sendable {
    public let name: String
    public let bytes: UInt64
    public let sha256: String
    public let urls: [URL]
    public init(name: String, bytes: UInt64, sha256: String, urls: [URL]) {
        self.name = name; self.bytes = bytes; self.sha256 = sha256; self.urls = urls
    }
}
public struct ModelDownloadSpec: Codable, Sendable {
    public let id: LocalModelID
    public let version: String
    public let files: [ModelDownloadFile]
    public let sourceAvailable: Bool
    public let conversion: ModelConversionPlan?
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.bytes } }
    public var requiredSpaceBytes: UInt64 { totalBytes + (conversion?.outputEstimateBytes ?? 0) + (conversion?.diskReserveBytes ?? 512 << 20) }
    public init(id: LocalModelID, version: String, files: [ModelDownloadFile], sourceAvailable: Bool = true, conversion: ModelConversionPlan? = nil) {
        self.id = id; self.version = version; self.files = files; self.sourceAvailable = sourceAvailable; self.conversion = conversion
    }
}
public struct ModelDownloadCatalog: Codable, Sendable {
    public let models: [ModelDownloadSpec]
    public static func read(_ url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}
public enum ModelRangePolicy {
    /// A 200 response to Range replaces the partial file; it must never be appended.
    public static func startingOffset(status: Int, requested: UInt64, contentRange: String?) throws -> UInt64 {
        if status == 200 { return 0 }
        guard status == 206, let contentRange, contentRange.hasPrefix("bytes \(requested)-") else { throw ModelDownloadError.http }
        return requested
    }
}
public protocol ModelDownloadTransport: Sendable {
    func transfer(url: URL, offset: UInt64, destination: URL, expectedBytes: UInt64,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws
}

/// Ephemeral URLSession streams directly into app-owned partial files, never holding a weight in RAM.
public struct PublicModelDownloadTransport: ModelDownloadTransport {
    public init() {}
    public func transfer(url: URL, offset: UInt64, destination: URL, expectedBytes: UInt64,
                         progress: @escaping @Sendable (UInt64) -> Void) async throws {
        let transfer = Transfer(destination: destination, offset: offset, expected: expectedBytes, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await transfer.run(url)
        } onCancel: { transfer.cancel() }
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let destination: URL, offset: UInt64, expected: UInt64
        private let progress: @Sendable (UInt64) -> Void
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        // The remaining state is confined to the session's serial delegate queue.
        private var continuation: CheckedContinuation<Void, any Error>?
        private var session: URLSession?
        private var file: FileHandle?
        private var count: UInt64 = 0
        private var failure: (any Error)?
        init(destination: URL, offset: UInt64, expected: UInt64, progress: @escaping @Sendable (UInt64) -> Void) {
            self.destination = destination; self.offset = offset; self.expected = expected; self.progress = progress
        }
        func run(_ url: URL) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                lock.lock(); self.task = task; let stopped = cancelled; lock.unlock()
                task.resume(); if stopped { task.cancel() }
            }
        }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let response = response as? HTTPURLResponse else { throw ModelDownloadError.http }
                count = try ModelRangePolicy.startingOffset(status: response.statusCode, requested: offset,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"))
                guard count <= expected else { throw ModelDownloadError.http }
                if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init),
                   length != expected - count { throw ModelDownloadError.http }
                file = try FileHandle(forWritingTo: destination)
                try file?.truncate(atOffset: count); try file?.seek(toOffset: count)
                completionHandler(.allow)
            } catch { failure = error; completionHandler(.cancel) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                guard count <= expected, UInt64(data.count) <= expected - count else { throw ModelDownloadError.http }
                let free = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard free > Int64(data.count) + 16 * 1024 * 1024 else { throw ModelDownloadError.diskFull }
                try file?.write(contentsOf: data); count += UInt64(data.count); progress(count)
            } catch {
                let cocoa = error as NSError
                failure = cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteOutOfSpaceError ? ModelDownloadError.diskFull : error
                dataTask.cancel()
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            do { try file?.synchronize(); try file?.close() } catch { failure = failure ?? ModelDownloadError.io }
            file = nil
            let result = failure ?? error.map(Self.map)
            if let result { continuation?.resume(throwing: result) }
            else if count != expected { continuation?.resume(throwing: ModelDownloadError.offline) }
            else { continuation?.resume() }
            continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
        }
        static func map(_ error: any Error) -> any Error {
            guard let error = error as? URLError else { return ModelDownloadError.io }
            switch error.code {
            case .cancelled: return CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed: return ModelDownloadError.certificate
            case .userAuthenticationRequired: return ModelDownloadError.proxy
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost: return ModelDownloadError.offline
            default: return ModelDownloadError.http
            }
        }
    }
}

public actor ModelDownloader {
    public let root: URL
    private let transport: any ModelDownloadTransport
    private let converter: (any ModelConverting)?
    private let freeBytes: @Sendable () throws -> UInt64
    private let trash: @Sendable (URL) async throws -> Void
    private var active: Set<LocalModelID> = []
    public init(root: URL, transport: any ModelDownloadTransport = PublicModelDownloadTransport(),
                converter: (any ModelConverting)? = nil,
                freeBytes: @escaping @Sendable () throws -> UInt64,
                trash: @escaping @Sendable (URL) async throws -> Void) {
        self.root = root; self.transport = transport; self.converter = converter; self.freeBytes = freeBytes; self.trash = trash
    }
    public func installedURL(_ spec: ModelDownloadSpec) throws -> URL {
        guard spec.version.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw ModelDownloadError.unsafePath }
        return try safe(root.appendingPathComponent("installed/\(spec.id.rawValue)-\(spec.version)"))
    }
    /// Fast inventory only: a verified directory rename has happened. Health/inference is a separate check.
    public func hasInstalledFiles(_ spec: ModelDownloadSpec) throws -> Bool {
        let directory = try installedURL(spec)
        if spec.conversion != nil { return (try? validateConverted(spec, directory: directory, hashFiles: false)) == true }
        for item in spec.files {
            guard !item.name.contains("/"), item.name != ".", item.name != ".." else { throw ModelDownloadError.unsafePath }
            let url = try safe(directory.appendingPathComponent(item.name))
            guard FileManager.default.fileExists(atPath: url.path), try size(url) == item.bytes else { return false }
        }
        return !spec.files.isEmpty
    }
    public func download(_ spec: ModelDownloadSpec, consent: Bool,
                         progress: @escaping @Sendable (Double) -> Void,
                         stage: @escaping @Sendable (ModelDownloadStage) -> Void = { _ in }) async throws -> URL {
        guard consent else { throw ModelDownloadError.consentRequired }
        guard spec.sourceAvailable, !spec.files.isEmpty else { throw ModelDownloadError.sourceUnavailable }
        guard !active.contains(spec.id) else { throw ModelDownloadError.busy }
        guard spec.version.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw ModelDownloadError.unsafePath }
        guard spec.files.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("/") && $0.name != "." && $0.name != ".." }) else { throw ModelDownloadError.unsafePath }
        active.insert(spec.id); defer { active.remove(spec.id) }
        let installed = try installedURL(spec)
        if FileManager.default.fileExists(atPath: installed.path) {
            let valid = spec.conversion == nil ? try verify(spec, directory: installed) : (try? validateConverted(spec, directory: installed, hashFiles: true)) == true
            if valid { progress(1); return installed }
        }
        let staging = try safe(root.appendingPathComponent("partial/\(spec.id.rawValue)-\(spec.version)"))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stored = try spec.files.reduce(UInt64(0)) { sum, file in
            let url = try safe(staging.appendingPathComponent(file.name))
            return sum + (FileManager.default.fileExists(atPath: url.path) ? min(file.bytes, try size(url)) : 0)
        }
        guard try freeBytes() >= spec.requiredSpaceBytes - stored else { throw ModelDownloadError.diskFull }
        stage(.downloading)
        var completed: UInt64 = 0
        for item in spec.files {
            try Task.checkCancellation()
            guard !item.name.isEmpty, !item.name.contains("/"), item.name != ".", item.name != "..",
                  item.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  !item.urls.isEmpty, item.urls.allSatisfy({ $0.scheme == "https" }) else { throw ModelDownloadError.unsafePath }
            let file = try safe(staging.appendingPathComponent(item.name))
            if FileManager.default.fileExists(atPath: file.path), try valid(item, file) { completed += item.bytes; continue }
            if !FileManager.default.fileExists(atPath: file.path) { try createPartial(file) }
            var failure: any Error = ModelDownloadError.sourceUnavailable
            var succeeded = false
            for url in item.urls {
              for _ in 0..<2 { // A resumed prefix can be corrupt; retry this mirror once from byte zero.
                try Task.checkCancellation()
                var offset = try size(file)
                if offset >= item.bytes { let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 0); try handle.close(); offset = 0 }
                guard try freeBytes() >= item.bytes - offset + (spec.conversion?.outputEstimateBytes ?? 0)
                    + (spec.conversion?.diskReserveBytes ?? 512 << 20) else { throw ModelDownloadError.diskFull }
                let base = completed, total = spec.totalBytes
                do {
                    try await transport.transfer(url: url, offset: offset, destination: file, expectedBytes: item.bytes) {
                        progress(Double(base + $0) / Double(max(1, total)))
                    }
                    try Task.checkCancellation()
                    guard try valid(item, file) else { throw ModelDownloadError.checksum }
                    succeeded = true; break
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failure = error
                    if error as? ModelDownloadError == .checksum { try await trash(file) }
                    if !FileManager.default.fileExists(atPath: file.path) { try createPartial(file) }
                    if error as? ModelDownloadError == .checksum && offset > 0 { continue }
                    break
                }
              }
              if succeeded { break }
            }
            guard succeeded else { throw failure }
            completed += item.bytes
        }
        try Task.checkCancellation()
        stage(.verifying)
        guard try verify(spec, directory: staging) else { throw ModelDownloadError.checksum }
        var publish = staging
        if let plan = spec.conversion {
            guard let converter else { throw ModelDownloadError.conversion }
            guard try freeBytes() >= plan.outputEstimateBytes + plan.diskReserveBytes else { throw ModelDownloadError.diskFull }
            let converted = try safe(root.appendingPathComponent("converted/\(spec.id.rawValue)-\(spec.version)"))
            if FileManager.default.fileExists(atPath: converted.path), (try? validateConverted(spec, directory: converted, hashFiles: true)) != true {
                try await trash(converted) // Interrupted conversion restarts from verified source, never from a partial tensor.
            }
            try FileManager.default.createDirectory(at: converted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            stage(.converting)
            let receipt = try await converter.convert(source: staging, stage: converted, spec: spec)
            try Task.checkCancellation()
            guard receipt.reloadVerified else { throw ModelDownloadError.reloadFailed }
            stage(.verifying)
            guard try validateConverted(spec, directory: converted, hashFiles: true) else { throw ModelDownloadError.reloadFailed }
            publish = converted
        }
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installed.path) { try await trash(installed) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: publish, to: installed)
        progress(1); return installed
    }
    public func moveToTrash(_ spec: ModelDownloadSpec) async throws {
        guard !active.contains(spec.id) else { throw ModelDownloadError.busy }
        for name in ["installed", "partial", "converted"] {
            let url = try safe(root.appendingPathComponent("\(name)/\(spec.id.rawValue)-\(spec.version)"))
            if FileManager.default.fileExists(atPath: url.path) { try await trash(url) }
        }
    }
    public func originalDownloadBytes(_ spec: ModelDownloadSpec) throws -> UInt64? {
        guard spec.conversion != nil, !active.contains(spec.id) else { return nil }
        _ = try installedRecord(spec) // Published, reload-verified converted files must still exist.
        let directory = try safe(root.appendingPathComponent("partial/\(spec.id.rawValue)-\(spec.version)"))
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let total = try spec.files.reduce(UInt64(0)) { value, file in
            let url = try safe(directory.appendingPathComponent(file.name))
            return value + (FileManager.default.fileExists(atPath: url.path) ? try size(url) : 0)
        }
        return total > 0 ? total : nil
    }
    public func moveOriginalToTrash(_ spec: ModelDownloadSpec) async throws {
        guard !active.contains(spec.id) else { throw ModelDownloadError.busy }
        guard try originalDownloadBytes(spec) != nil else { return }
        try await trash(safe(root.appendingPathComponent("partial/\(spec.id.rawValue)-\(spec.version)")))
    }
    /// Called only after the downloader has verified and atomically published its files.
    public func installedRecord(_ spec: ModelDownloadSpec) throws -> (URL, [ModelInstalledFile]) {
        let directory = try safe(root.appendingPathComponent("installed/\(spec.id.rawValue)-\(spec.version)"))
        if spec.conversion != nil {
            guard try validateConverted(spec, directory: directory, hashFiles: false) else { throw ModelDownloadError.reloadFailed }
            let receipt = try JSONDecoder().decode(ModelConversionReceipt.self,
                from: Data(contentsOf: directory.appendingPathComponent("conversion-receipt.json")))
            return (directory, receipt.files)
        }
        guard try verify(spec, directory: directory) else { throw ModelDownloadError.checksum }
        return (directory, spec.files.map { .init(name: $0.name, sha256: $0.sha256, bytes: $0.bytes) })
    }
    private func validateConverted(_ spec: ModelDownloadSpec, directory: URL, hashFiles: Bool) throws -> Bool {
        guard let plan = spec.conversion else { return false }
        let receiptURL = try safe(directory.appendingPathComponent("conversion-receipt.json"))
        guard try size(receiptURL) < 2_000_000 else { return false }
        let receipt = try JSONDecoder().decode(ModelConversionReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.schemaVersion == 1, receipt.sourceVersion == spec.version, receipt.runtimeVersion == plan.runtimeVersion,
              receipt.dtype == "float16", receipt.bits == plan.bits, receipt.groupSize == plan.groupSize,
              receipt.reloadVerified, receipt.parameterCount > 0, receipt.quantizedLayers > 0,
              Set(receipt.files.map(\.name)).count == receipt.files.count,
              Set(["model.safetensors", "config.json", "tokenizer_config.json", "preprocessor_config.json", "chat_template.json", "LICENSE", "quantization_config.json"]).isSubset(of: Set(receipt.files.map(\.name))) else { return false }
        let weights = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "safetensors" }
        guard weights.map(\.lastPathComponent) == ["model.safetensors"] else { return false }
        for file in receipt.files {
            guard !file.name.isEmpty, !file.name.contains("/"), file.name != ".", file.name != "..",
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return false }
            let url = try safe(directory.appendingPathComponent(file.name))
            guard try size(url) == file.bytes else { return false }
            if hashFiles, try !valid(.init(name: file.name, bytes: file.bytes, sha256: file.sha256, urls: []), url) { return false }
        }
        let quantURL = try safe(directory.appendingPathComponent("quantization_config.json"))
        guard let quant = try JSONSerialization.jsonObject(with: Data(contentsOf: quantURL)) as? [String: Any],
              quant["bits"] as? Int == plan.bits, quant["group_size"] as? Int == plan.groupSize,
              quant["scope"] as? String == "all_supported_layers" else { return false }
        return true
    }
    private func verify(_ spec: ModelDownloadSpec, directory: URL) throws -> Bool {
        for item in spec.files { if try !valid(item, safe(directory.appendingPathComponent(item.name))) { return false } }
        return true
    }
    private func valid(_ item: ModelDownloadFile, _ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), try size(url) == item.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == item.sha256
    }
    // URL resource values can cache the pre-transfer size; always stat fresh after streaming writes.
    private func size(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw ModelDownloadError.unsafePath }
        return size
    }
    private func createPartial(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ENOSPC ? ModelDownloadError.diskFull : ModelDownloadError.io }
        guard close(descriptor) == 0 else { throw ModelDownloadError.io }
    }
    private func safe(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ModelDownloadError.unsafePath }
        var ancestor = path
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ModelDownloadError.unsafePath }
            ancestor.deleteLastPathComponent()
        }
        return path
    }
}
