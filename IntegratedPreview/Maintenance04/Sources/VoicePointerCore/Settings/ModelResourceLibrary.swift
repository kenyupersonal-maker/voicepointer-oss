// T11: One external-resource contract for downloads, migration, menus and workers.
import Foundation
import Darwin

public struct ModelResourceEntry: Codable, Sendable {
    public let directory: String, version: String, source: String
    public let files: [ModelInstalledFile]
    public init(directory: String, version: String, source: String, files: [ModelInstalledFile]) {
        self.directory = directory; self.version = version; self.source = source; self.files = files
    }
}
public struct ModelResourceIndex: Codable, Sendable {
    public let schemaVersion: Int
    public var models: [String: ModelResourceEntry]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", models }
    public init(models: [String: ModelResourceEntry] = [:]) { schemaVersion = 1; self.models = models }
}
public struct ModelResourceLibrary: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static var current: Self { .init(root: IntegratedRuntimePaths.modelsRoot) }
    public static let identifiers: Set<String> = ["qwen06-rolling", "qwen17-rolling", "punctuation"]
    public static func requiredFiles(_ id: String) -> Set<String> {
        let qwen: Set<String> = ["config.json", "model.safetensors", "preprocessor_config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "chat_template.json"]
        return id == "punctuation" ? ["model.int8.onnx"] : id == "qwen17-rolling" ? qwen.union(["quantization_config.json"]) : id == "qwen06-rolling" ? qwen : []
    }
    public func index() throws -> ModelResourceIndex {
        let path = try confined(root.appendingPathComponent("library.json"))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return .init() }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.uint64Value ?? UInt64.max) < 2_000_000 else { throw ModelDownloadError.unsafePath }
        let value = try JSONDecoder().decode(ModelResourceIndex.self, from: Data(contentsOf: path))
        guard value.schemaVersion == 1, Set(value.models.keys).isSubset(of: Self.identifiers) else { throw ModelDownloadError.unsafePath }
        return value
    }
    public func entry(_ id: String) -> ModelResourceEntry? { (try? index())?.models[id] }
    public func directory(_ id: String) -> URL? {
        guard let entry = entry(id), valid(entry, id: id) else { return nil }
        return try? confined(root.appendingPathComponent(entry.directory, isDirectory: true))
    }
    public func isReady(_ id: String) -> Bool { directory(id) != nil }
    public func integrityFiles(_ id: String) -> [LocalModelIntegrityFile] {
        guard let entry = entry(id), valid(entry, id: id) else { return [] }
        return entry.files.map { .init(path: entry.directory + "/" + $0.name, sha256: $0.sha256, size: $0.bytes) }
    }
    public func register(_ id: String, directory: URL, version: String, source: String, files: [ModelInstalledFile]) throws {
        guard Self.identifiers.contains(id), ["download", "migration"].contains(source) else { throw ModelDownloadError.unsafePath }
        let directory = try confined(directory)
        let relative = String(directory.path.dropFirst(root.path.count + 1))
        let entry = ModelResourceEntry(directory: relative, version: version, source: source, files: files)
        guard valid(entry, id: id) else { throw ModelDownloadError.checksum }
        var value = try index(); value.models[id] = entry
        try write(value)
    }
    public func unregister(_ id: String) throws {
        var value = try index(); value.models.removeValue(forKey: id); try write(value)
    }
    public func managedDirectory(_ id: String) throws -> URL? {
        guard let entry = entry(id) else { return nil }
        guard Self.identifiers.contains(id), entry.directory.hasPrefix("installed/"),
              !entry.directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ModelDownloadError.unsafePath }
        return try confined(root.appendingPathComponent(entry.directory))
    }
    private func write(_ value: ModelResourceIndex) throws {
        _ = try confined(root.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Foundation's atomic writer can use an NSItemReplacementDirectory outside the confined root.
        // Explicit sibling staging keeps publication atomic under the same sandbox and filesystem.
        let temporary = try confined(root.appendingPathComponent(".library-" + UUID().uuidString + ".partial"))
        try encoder.encode(value).write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw ModelDownloadError.io }
        guard rename(temporary.path, root.appendingPathComponent("library.json").path) == 0 else { throw ModelDownloadError.io }
    }
    private func valid(_ entry: ModelResourceEntry, id: String) -> Bool {
        guard !entry.directory.isEmpty, !entry.directory.hasPrefix("/"),
              !entry.version.isEmpty, ["download", "migration"].contains(entry.source),
              entry.directory.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }),
              entry.directory.hasPrefix("installed/"), !entry.files.isEmpty,
              Self.identifiers.contains(id), Self.requiredFiles(id).isSubset(of: Set(entry.files.map(\.name))),
              Set(entry.files.map(\.name)).count == entry.files.count else { return false }
        return entry.files.allSatisfy { file in
            guard !file.name.isEmpty, !file.name.contains("/"), file.name != ".", file.name != "..", file.bytes > 0,
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let url = try? confined(root.appendingPathComponent(entry.directory).appendingPathComponent(file.name)),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.uint64Value == file.bytes else { return false }
            return true
        }
    }
    private func confined(_ path: URL) throws -> URL {
        let url = path.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), !url.pathComponents.contains("keep-0.5.50") else { throw ModelDownloadError.unsafePath }
        var ancestor = url
        while ancestor.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw ModelDownloadError.unsafePath
            }
            ancestor.deleteLastPathComponent()
        }
        return url
    }
}
