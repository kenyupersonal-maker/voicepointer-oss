// T12 2026-10-02: Metadata-only inventory, opaque bounded snapshots, exact own-path Trash operations.
import Foundation

public enum AppDataFailure: String, Error, Sendable { case unsafePath, inventory, snapshotTooLarge, snapshot, removal, loginItem }
public struct AppDataSummary: Sendable, Equatable {
    public let items: [ManagedDataItem]
    public let totalBytes: UInt64
    public init(items: [ManagedDataItem], totalBytes: UInt64) { self.items = items; self.totalBytes = totalBytes }
}

public struct AppDataPaths: Sendable {
    public static let bundleID = "com.kenyu.voicepointer.mac"
    public let home: URL
    public init(home: URL) { self.home = home }
    public var data: URL { home.appendingPathComponent("Library/Application Support/" + Self.bundleID) }
    public var preferences: URL { home.appendingPathComponent("Library/Preferences/" + Self.bundleID + ".plist") }
    public var cache: URL { home.appendingPathComponent("Library/Caches/" + Self.bundleID) }
    public var touchSamples: [URL] { ["touch-samples.jsonl", "touch-samples.jsonl.1"].map { cache.appendingPathComponent($0) } }
    public var loginItem: URL { home.appendingPathComponent("Library/LaunchAgents/" + Self.bundleID + ".plist") }
    public var backups: URL { home.appendingPathComponent("Library/Application Support/VoicePointer-Migration-Backups") }
    public var removalTargets: [URL] { [data, preferences, cache, loginItem] }
}

/// No private file decoding. Only Models/library.json (T11 public resource metadata) is decoded.
public struct AppDataManagement: Sendable {
    public typealias Trash = @Sendable (URL) throws -> Void
    public let paths: AppDataPaths
    private let trash: Trash
    public init(paths: AppDataPaths, trash: @escaping Trash) { self.paths = paths; self.trash = trash }
    private static let protected = ["keep-0.5.50", "integrated-trial-04.app"]

    public static func validate(_ url: URL, inside root: URL, allowRoot: Bool = false) throws {
        guard !url.pathComponents.contains(".."), !root.pathComponents.contains(".."),
              !url.pathComponents.contains(where: { protected.contains($0) }),
              url.path == root.path && allowRoot || url.path.hasPrefix(root.path + "/") else { throw AppDataFailure.unsafePath }
        var ancestor = url
        while ancestor.path != "/" {
            if let type = try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type],
               type as? FileAttributeType == .typeSymbolicLink { throw AppDataFailure.unsafePath }
            ancestor.deleteLastPathComponent()
        }
    }
    /// Metadata traversal fails closed on links, protected descendants, special files, or unreadable content.
    public static func bytes(_ url: URL, inside root: URL) throws -> UInt64 {
        try validate(url, inside: root, allowRoot: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeRegular { return (attributes[.size] as? NSNumber)?.uint64Value ?? 0 }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AppDataFailure.unsafePath }
        var total: UInt64 = 0
        for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            let size = try bytes(child, inside: root)
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { throw AppDataFailure.inventory }
            total = sum.partialValue
        }
        return total
    }
    public func inspect() throws -> AppDataSummary {
        let library = ModelResourceLibrary(root: paths.data.appendingPathComponent("Models"))
        let index = try library.index()
        var items: [ManagedDataItem] = []
        for (id, resource) in [(ManagedDataID.model17, "qwen17-rolling"), (.model06, "qwen06-rolling"), (.punctuation, "punctuation")] {
            if index.models[resource] != nil {
                guard let url = try library.managedDirectory(resource) else { throw AppDataFailure.inventory }
                items.append(.init(id: id, sizeBytes: try Self.bytes(url, inside: paths.data)))
            }
        }
        let partialBytes = try unusedModelPaths().reduce(UInt64(0)) { try $0 + Self.bytes($1, inside: paths.data) }
        if partialBytes > 0 { items.append(.init(id: .modelDownloads, sizeBytes: partialBytes)) }
        let touchBytes = try paths.touchSamples.reduce(UInt64(0)) { try $0 + Self.bytes($1, inside: paths.home) }
        if touchBytes > 0 { items.append(.init(id: .touchSamples, sizeBytes: touchBytes)) }
        let logBytes = try diagnosticPaths().reduce(UInt64(0)) { try $0 + Self.bytes($1, inside: paths.home) }
        if logBytes > 0 { items.append(.init(id: .diagnosticLogs, sizeBytes: logBytes)) }
        let total = try paths.removalTargets.reduce(UInt64(0)) { try $0 + Self.bytes($1, inside: paths.home) }
        return .init(items: items, totalBytes: total)
    }
    public func remove(_ id: ManagedDataID) throws {
        switch id {
        case .personalLexicon: try clearLexicon()
        case .diagnosticLogs:
            let targets = try diagnosticPaths()
            for url in targets { _ = try Self.bytes(url, inside: paths.home) }
            for url in targets { try move(url) }
        case .touchSamples:
            for url in paths.touchSamples { _ = try Self.bytes(url, inside: paths.home) }
            for url in paths.touchSamples { try move(url) }
        case .modelDownloads:
            let unused = try unusedModelPaths()
            for url in unused { _ = try Self.bytes(url, inside: paths.data) }
            for url in unused { try move(url) }
        case .model17, .model06, .punctuation:
            let key = id == .model17 ? "qwen17-rolling" : id == .model06 ? "qwen06-rolling" : "punctuation"
            let library = ModelResourceLibrary(root: paths.data.appendingPathComponent("Models"))
            _ = try library.index() // Malformed schemas must surface, never silently become empty.
            if let url = try library.managedDirectory(key) { try move(url) }
            try library.unregister(key)
        }
    }
    public func clearLexicon() throws { try move(paths.data.appendingPathComponent("Lexicon")) }
    private func diagnosticPaths() throws -> [URL] {
        try Self.validate(paths.cache, inside: paths.home)
        guard FileManager.default.fileExists(atPath: paths.cache.path) else { return [] }
        let excluded = Set(paths.touchSamples.map(\.lastPathComponent))
        return try FileManager.default.contentsOfDirectory(at: paths.cache, includingPropertiesForKeys: nil)
            .filter { !excluded.contains($0.lastPathComponent) }
    }
    private func unusedModelPaths() throws -> [URL] {
        let root = paths.data.appendingPathComponent("Models")
        let library = ModelResourceLibrary(root: root)
        let index = try library.index()
        let known = Set(index.models.values.map { root.appendingPathComponent($0.directory).standardizedFileURL.path })
        let installed = root.appendingPathComponent("installed")
        try Self.validate(installed, inside: paths.data)
        var unused = [root.appendingPathComponent("partial"), root.appendingPathComponent("converted")]
        if FileManager.default.fileExists(atPath: installed.path) {
            unused += try FileManager.default.contentsOfDirectory(at: installed, includingPropertiesForKeys: nil)
                .filter { !known.contains($0.standardizedFileURL.path) }
        }
        return unused
    }
    private func move(_ url: URL) throws {
        _ = try Self.bytes(url, inside: paths.home) // Complete preflight before Trash; never follow links.
        if FileManager.default.fileExists(atPath: url.path) { try trash(url) }
    }
    /// Byte-for-byte copy. Excludes models, recordings and logs; decimal payload cap leaves 1 MB headroom.
    @discardableResult public func snapshot() throws -> URL {
        let excluded: Set<String> = ["Models", "ModelDownloads", ".cache", "Logs", "logs", "runtime.log"]
        let audio: Set<String> = ["wav", "pcm", "mp3", "m4a", "flac", "aiff", "caf", "ogg"]
        var files: [(URL, String)] = []
        func collect(_ source: URL, relative: String) throws {
            try Self.validate(source, inside: paths.home)
            guard !excluded.contains(source.lastPathComponent), !audio.contains(source.pathExtension.lowercased()) else { return }
            guard FileManager.default.fileExists(atPath: source.path) else { return }
            let type = try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try collect(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else if type == .typeRegular { files.append((source, relative)) }
            else { throw AppDataFailure.unsafePath }
        }
        try collect(paths.data, relative: "ApplicationSupport-" + AppDataPaths.bundleID)
        try collect(paths.preferences, relative: AppDataPaths.bundleID + ".plist")
        let size = try files.reduce(UInt64(0)) { try $0 + Self.bytes($1.0, inside: paths.home) }
        guard size < 49_000_000 else { throw AppDataFailure.snapshotTooLarge }
        let target = paths.backups.appendingPathComponent("data-removal-" + UUID().uuidString)
        try Self.validate(target, inside: paths.home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (source, relative) in files {
            let destination = target.appendingPathComponent(relative)
            try Self.validate(destination, inside: target)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: destination)
        }
        guard try Self.bytes(target, inside: paths.home) < 50_000_000 else { throw AppDataFailure.snapshotTooLarge }
        return target
    }
    /// Caller has obtained the second UI confirmation and stopped all writers first. App stays for manual uninstall.
    public func prepareUninstall() throws {
        for url in paths.removalTargets { _ = try Self.bytes(url, inside: paths.home) }
        do { _ = try snapshot() } // Failure leaves every active target untouched.
        catch { throw error as? AppDataFailure ?? .snapshot }
        for url in paths.removalTargets { try move(url) }
    }
}

/// Uninstall helpers refuse live writers. No process is stopped, and tests supply only synthetic identities.
public enum AppDataProcessGuard {
    public struct Identity: Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let bundlePath: String?
        public let executablePath: String?
        public init(pid: Int32, bundleID: String?, bundlePath: String?, executablePath: String?) {
            self.pid = pid; self.bundleID = bundleID; self.bundlePath = bundlePath; self.executablePath = executablePath
        }
    }
    public static func mayUninstall(_ processes: [Identity], helperPID: Int32) -> Bool {
        !processes.contains {
            $0.pid != helperPID && $0.bundleID == AppDataPaths.bundleID
                && ($0.bundlePath == "/Applications/VoicePointer.app"
                    || $0.executablePath == "/Applications/VoicePointer.app/Contents/MacOS/VoicePointerPreview")
        }
    }
}
