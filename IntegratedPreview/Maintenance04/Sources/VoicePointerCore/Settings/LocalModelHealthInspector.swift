// T4 2026-10-02: Read-only integrity + lightweight container loading. Never opens audio or starts ASR.
import Foundation
import CryptoKit

public struct LocalModelIntegrityFile: Sendable, Decodable {
    public let path: String
    public let sha256: String?
    public let size: UInt64?
    public init(path: String, sha256: String?, size: UInt64?) { self.path = path; self.sha256 = sha256; self.size = size }
}
public struct LocalModelCheckSpecification: Sendable {
    public let id: LocalModelID, root: URL, files: [LocalModelIntegrityFile], hardware: SettingsHardwareInfo
    public let runtimeExecutable: URL, runtimeRoot: URL
    public init(id: LocalModelID, root: URL, files: [LocalModelIntegrityFile], hardware: SettingsHardwareInfo, runtimeExecutable: URL, runtimeRoot: URL? = nil) {
        self.id = id; self.root = root; self.files = files; self.hardware = hardware; self.runtimeExecutable = runtimeExecutable
        self.runtimeRoot = runtimeRoot ?? root
    }
}
public enum LocalModelHealthInspector {
    public static func fingerprint(_ spec: LocalModelCheckSpecification) -> String? {
        let fm = FileManager.default
        let root = spec.root.resolvingSymlinksInPath().path + "/"
        var metadata = [String]()
        for entry in spec.files {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { return nil }
            let path = spec.root.appendingPathComponent(entry.path).resolvingSymlinksInPath().path
            guard path.hasPrefix(root), let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date,
                  let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
            metadata.append("\(path)|\(size.uint64Value)|\(modified.timeIntervalSince1970)|\(inode.uint64Value)|\(entry.sha256 ?? "")|\(entry.size ?? 0)")
        }
        guard !metadata.isEmpty, let attrs = try? fm.attributesOfItem(atPath: spec.runtimeExecutable.path),
              let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date,
              let inode = attrs[.systemFileNumber] as? NSNumber, fm.isExecutableFile(atPath: spec.runtimeExecutable.path) else { return nil }
        metadata.append("\(spec.runtimeExecutable.path)|\(size)|\(modified.timeIntervalSince1970)|\(inode)")
        return SHA256.hash(data: Data(metadata.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func check(_ spec: LocalModelCheckSpecification, force: Bool = false) async -> EngineHealthResult {
        let task = Task.detached(priority: .utility) {
            let key = "engine.model.verifiedFingerprint." + spec.id.rawValue
            let before = fingerprint(spec)
            if !force, spec.hardware.supports(spec.id), let before,
               UserDefaults.standard.string(forKey: key) == before { return EngineHealthResult.passed(.localContainerLoadable) }
            let result = inspect(spec)
            if result == .passed(.localContainerLoadable), let before, !Task.isCancelled,
               fingerprint(spec) == before { UserDefaults.standard.set(before, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            return result
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    private static func inspect(_ spec: LocalModelCheckSpecification) -> EngineHealthResult {
        guard spec.hardware.supports(spec.id) else { return .failed(.hardwareUnsuitable) }
        guard !spec.files.isEmpty else { return .failed(.modelNotDownloaded) }
        let fm = FileManager.default
        let root = spec.root.resolvingSymlinksInPath().path + "/"
        let urls = spec.files.compactMap { entry -> URL? in
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { return nil }
            let url = spec.root.appendingPathComponent(entry.path).resolvingSymlinksInPath()
            return url.path.hasPrefix(root) ? url : nil
        }
        guard urls.count == spec.files.count else { return .failed(.modelCorrupt) }
        let present = urls.filter { fm.fileExists(atPath: $0.path) }.count
        guard present > 0 else { return .failed(.modelNotDownloaded) }
        guard present == urls.count else { return .failed(.modelCorrupt) }
        let runtime = spec.runtimeExecutable.resolvingSymlinksInPath()
        guard runtime.path.hasPrefix(spec.runtimeRoot.resolvingSymlinksInPath().path + "/"),
              (try? fm.attributesOfItem(atPath: runtime.path)[.type]) as? FileAttributeType == .typeRegular,
              fm.isExecutableFile(atPath: runtime.path) else { return .failed(.localLoadFailed) }
        for (entry, url) in zip(spec.files, urls) {
            if Task.isCancelled { return .failed(.unavailable) }
            guard let expected = entry.sha256, expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let expectedSize = entry.size else { return .failed(.unavailable) } // Missing authoritative checksum is not a pass.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.uint64Value == expectedSize else { return .failed(.modelCorrupt) }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    if Task.isCancelled { return .failed(.unavailable) }
                    digest.update(data: data)
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { return .failed(.modelCorrupt) }
                if url.pathExtension == "safetensors" {
                    guard try containerLoads(url, size: expectedSize) else { return .failed(.localLoadFailed) }
                } else if url.pathExtension == "json" {
                    guard expectedSize <= 32_000_000,
                          (try JSONSerialization.jsonObject(with: Data(contentsOf: url))) is [String: Any] else { return .failed(.localLoadFailed) }
                }
            } catch { return .failed(.localLoadFailed) }
        }
        // The Python runtime is present; model containers were read and parsed without loading tensor arrays.
        // This is intentionally not a model inference or microphone acceptance claim.
        return .passed(.localContainerLoadable)
    }
    private static func containerLoads(_ url: URL, size: UInt64) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { return false }
        let headerSize = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard headerSize > 0, headerSize <= 16_000_000, size >= 8 + headerSize,
              let header = try handle.read(upToCount: Int(headerSize)), header.count == Int(headerSize),
              let json = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { return false }
        let tensors = json.filter { $0.key != "__metadata__" }
        guard !tensors.isEmpty else { return false }
        let dataBytes = size - 8 - headerSize
        return tensors.values.allSatisfy { raw in
            guard let tensor = raw as? [String: Any], let dtype = tensor["dtype"] as? String,
                  ["F64", "F32", "F16", "BF16", "I64", "I32", "I16", "I8", "U64", "U32", "U16", "U8", "BOOL", "F8_E4M3", "F8_E5M2"].contains(dtype),
                  let shape = tensor["shape"] as? [NSNumber], shape.allSatisfy({ $0.int64Value >= 0 }),
                  let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2,
                  offsets[0].int64Value >= 0, offsets[1].uint64Value >= offsets[0].uint64Value,
                  offsets[1].uint64Value <= dataBytes else { return false }
            return true
        }
    }
}
