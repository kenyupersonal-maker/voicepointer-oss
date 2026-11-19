import Foundation
import Darwin

public enum ProviderPreferencesError: Error, Sendable { case invalidConsentID }

public struct ProviderPreferences: Codable, Sendable, Equatable {
    public static let allowedConsentIDs: Set<String> = ["groq", "aliyun-beijing", "openai", "siliconflow"]
    public var selection: VoiceInputSelection
    public var learnCorrections: Bool
    /// Local-only teacher learning, default on from 0.5.60. Later explicit off persists.
    public var enhanceLearning: Bool
    private var teacherLearningDefaultsVersion: Int = 1
    public var applyPersonalLexicon: Bool
    /// Hand the lexicon's words to the recognizer on this Mac as hot words (only while the lexicon is applied).
    public var useHotwordsLocally: Bool
    public var useRecentContextLocally: Bool
    public var cloudConsent: Set<String>
    public var aliyunEndpoint: String
    public var onlineAPIConfiguration: OnlineAPIConfiguration?
    /// Display-only metadata. Never populated by reading/decrypting an existing credential.
    public var onlineAPIMaskedKey: String?
    public var onlineAPIAvailableModelIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case selection, learnCorrections, enhanceLearning, teacherLearningDefaultsVersion, applyPersonalLexicon, useHotwordsLocally, useRecentContextLocally, cloudConsent, aliyunEndpoint, onlineAPIConfiguration, onlineAPIMaskedKey, onlineAPIAvailableModelIDs
    }

    public init(selection: VoiceInputSelection? = nil, learnCorrections: Bool = false, enhanceLearning: Bool = true,
                applyPersonalLexicon: Bool = true, useHotwordsLocally: Bool = true, useRecentContextLocally: Bool = true,
                cloudConsent: Set<String> = [],
                aliyunEndpoint: String = AliEndpoint.defaultURLString,
                onlineAPIConfiguration: OnlineAPIConfiguration? = nil, onlineAPIMaskedKey: String? = nil,
                onlineAPIAvailableModelIDs: [String]? = nil) throws {
        self.selection = try selection ?? VoiceInputSelection()
        self.learnCorrections = learnCorrections
        self.enhanceLearning = enhanceLearning
        self.applyPersonalLexicon = applyPersonalLexicon
        self.useHotwordsLocally = useHotwordsLocally
        self.useRecentContextLocally = useRecentContextLocally
        guard cloudConsent.isSubset(of: Self.allowedConsentIDs) else { throw ProviderPreferencesError.invalidConsentID }
        self.cloudConsent = cloudConsent
        self.aliyunEndpoint = try AliEndpoint(aliyunEndpoint).url.absoluteString
        self.onlineAPIConfiguration = onlineAPIConfiguration
        self.onlineAPIMaskedKey = onlineAPIMaskedKey
        self.onlineAPIAvailableModelIDs = onlineAPIAvailableModelIDs
        if let onlineAPIConfiguration { _ = try onlineAPIConfiguration.validatedEndpoint() }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selection = try c.decodeIfPresent(VoiceInputSelection.self, forKey: .selection) ?? VoiceInputSelection()
        self.learnCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnCorrections) ?? false
        let priorTeacherVersion = try c.decodeIfPresent(Int.self, forKey: .teacherLearningDefaultsVersion) ?? 0
        let priorLearning = try c.decodeIfPresent(Bool.self, forKey: .enhanceLearning)
        self.enhanceLearning = priorTeacherVersion >= 1 ? (priorLearning ?? true) : true
        self.teacherLearningDefaultsVersion = 1
        self.applyPersonalLexicon = try c.decodeIfPresent(Bool.self, forKey: .applyPersonalLexicon) ?? true
        self.useHotwordsLocally = try c.decodeIfPresent(Bool.self, forKey: .useHotwordsLocally) ?? true
        self.useRecentContextLocally = try c.decodeIfPresent(Bool.self, forKey: .useRecentContextLocally) ?? true
        let consent = try c.decodeIfPresent(Set<String>.self, forKey: .cloudConsent) ?? []
        guard consent.isSubset(of: Self.allowedConsentIDs) else { throw ProviderPreferencesError.invalidConsentID }
        self.cloudConsent = consent
        self.aliyunEndpoint = try AliEndpoint(c.decodeIfPresent(String.self, forKey: .aliyunEndpoint) ?? AliEndpoint.defaultURLString).url.absoluteString
        self.onlineAPIConfiguration = try c.decodeIfPresent(OnlineAPIConfiguration.self, forKey: .onlineAPIConfiguration)
        self.onlineAPIMaskedKey = try c.decodeIfPresent(String.self, forKey: .onlineAPIMaskedKey)
        self.onlineAPIAvailableModelIDs = try c.decodeIfPresent([String].self, forKey: .onlineAPIAvailableModelIDs)
        if let onlineAPIConfiguration { _ = try onlineAPIConfiguration.validatedEndpoint() }
        if let onlineAPIAvailableModelIDs {
            guard let config = onlineAPIConfiguration, Set(onlineAPIAvailableModelIDs).count == onlineAPIAvailableModelIDs.count,
                  onlineAPIAvailableModelIDs.allSatisfy(config.provider.modelIDs.contains), onlineAPIAvailableModelIDs.contains(config.modelID) else { throw SettingsErrorProxy.invalid }
        }
    }
    private enum SettingsErrorProxy: Error { case invalid }
}

@MainActor
public final class ProviderSettingsStore {
    public struct Checkpoint {
        fileprivate let value: ProviderPreferences
        fileprivate let bytes: Data?
    }
    public enum SettingsError: Error, Sendable { case malformed, symlink, persistence(String) }
    public let fileURL: URL
    public private(set) var value: ProviderPreferences
    public var onChange: (@MainActor (ProviderPreferences) -> Void)?

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let existed: Bool = try Self.checkDestination(path: fileURL.path)
        if existed {
            guard let data = FileManager.default.contents(atPath: fileURL.path) else {
                throw SettingsError.persistence("read failed: \(Self.errnoString(errno))")
            }
            guard let prefs = try? JSONDecoder().decode(ProviderPreferences.self, from: data) else { throw SettingsError.malformed }
            value = prefs
        } else {
            value = try ProviderPreferences()
        }
    }

    public func update(_ newValue: ProviderPreferences) throws {
        let changed = value != newValue
        let encoded = try JSONEncoder().encode(newValue)
        _ = try JSONDecoder().decode(ProviderPreferences.self, from: encoded)  // roundtrip validation
        try Self.writeAtomically(encoded, to: fileURL)
        value = newValue
        if changed { onChange?(newValue) }
    }

    public func checkpoint() throws -> Checkpoint {
        let existed = try Self.checkDestination(path: fileURL.path)
        let bytes = existed ? FileManager.default.contents(atPath: fileURL.path) : nil
        guard !existed || bytes != nil else { throw SettingsError.malformed }
        return .init(value: value, bytes: bytes)
    }
    public func restore(_ checkpoint: Checkpoint, expected: ProviderPreferences) throws {
        guard value == expected else { throw SettingsError.malformed }
        if let bytes = checkpoint.bytes { try Self.writeAtomically(bytes, to: fileURL) }
        else if try Self.checkDestination(path: fileURL.path) {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        }
        let changed = value != checkpoint.value
        value = checkpoint.value
        if changed { onChange?(value) }
    }

    /// User-invoked recovery only. A malformed regular file is backed up byte for
    /// byte before defaults replace it; symlinks and other I/O failures are never reset.
    @discardableResult
    public static func recoverMalformed(fileURL: URL) throws -> URL {
        guard try checkDestination(path: fileURL.path),
              let original = FileManager.default.contents(atPath: fileURL.path) else {
            throw SettingsError.persistence("settings file unavailable")
        }
        guard (try? JSONDecoder().decode(ProviderPreferences.self, from: original)) == nil else {
            throw SettingsError.persistence("settings are valid; recovery refused")
        }
        let dir = fileURL.deletingLastPathComponent()
        try Self.ensureDirectory(dir)

        let backupURL = dir.appendingPathComponent(
            "\(fileURL.lastPathComponent).backup-\(UUID().uuidString)", isDirectory: false)
        let backupFD = try openTempFile(backupURL.path)
        var backupClosed = false
        do {
            try writeFully(fd: backupFD, data: original)
            try fsync(fd: backupFD)
            guard close(backupFD) == 0 else {
                backupClosed = true
                throw SettingsError.persistence("backup close failed")
            }
            backupClosed = true
        } catch {
            if !backupClosed { _ = close(backupFD) }
            unlinkQuiet(backupURL.path)
            throw error
        }
        guard try checkDestination(path: fileURL.path),
              FileManager.default.contents(atPath: fileURL.path) == original else {
            throw SettingsError.persistence("settings changed during recovery")
        }
        let defaults = try JSONEncoder().encode(ProviderPreferences())
        try writeAtomically(defaults, to: fileURL)
        return backupURL
    }

    private static func writeAtomically(_ encoded: Data, to fileURL: URL) throws {
        _ = try checkDestination(path: fileURL.path)
        let dir = fileURL.deletingLastPathComponent()
        try ensureDirectory(dir)

        let tmpPath = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp.\(UUID().uuidString)").path
        let fd = try openTempFile(tmpPath)
        var closed = false
        do {
            try writeFully(fd: fd, data: encoded)
            try fsync(fd: fd)
            let closeResult = close(fd)
            closed = true
            if closeResult != 0 {
                throw SettingsError.persistence("close: \(Self.errnoString(errno))")
            }
        } catch {
            if !closed { close(fd) }
            unlinkQuiet(tmpPath)
            throw error
        }
        do { _ = try checkDestination(path: fileURL.path) }
        catch { unlinkQuiet(tmpPath); throw error }
        if rename(tmpPath, fileURL.path) != 0 {
            let msg = errnoString(errno)
            unlinkQuiet(tmpPath)
            throw SettingsError.persistence("rename: \(msg)")
        }
    }

    public func snapshot(sessionID: UUID, lexiconRevision: Int) throws -> VoiceInputSnapshot {
        try VoiceInputSnapshot(sessionID: sessionID, selection: value.selection, lexiconRevision: lexiconRevision)
    }

    /// Returns true when the path exists as a regular file, false on ENOENT.
    /// Rejects symlinks (via lstat), non-regular files, and any other stat error.
    private static func checkDestination(path: String) throws -> Bool {
        var st = stat()
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw SettingsError.symlink }
            if (st.st_mode & S_IFMT) != S_IFREG {
                throw SettingsError.persistence("destination is not a regular file")
            }
            return true
        }
        if errno == ENOENT { return false }
        throw SettingsError.persistence("lstat: \(Self.errnoString(errno))")
    }

    private static func ensureDirectory(_ dir: URL) throws {
        var st = stat()
        if lstat(dir.path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw SettingsError.symlink }
            if (st.st_mode & S_IFMT) != S_IFDIR {
                throw SettingsError.persistence("parent is not a directory")
            }
            return  // existing parent permissions unchanged
        }
        guard errno == ENOENT else { throw SettingsError.persistence("lstat dir: \(Self.errnoString(errno))") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw SettingsError.persistence("mkdir: \(error)")
        }
    }

    private static func openTempFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SettingsError.persistence("open tmp: \(Self.errnoString(errno))")
        }
        return fd
    }

    private static func writeFully(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += Int(n); continue }
                if n == 0 { throw SettingsError.persistence("zero-byte write") }
                if errno == EINTR { continue }
                throw SettingsError.persistence("write: \(Self.errnoString(errno))")
            }
        }
    }

    private static func fsync(fd: Int32) throws {
        while true {
            if Darwin.fsync(fd) == 0 { return }
            if errno == EINTR { continue }
            throw SettingsError.persistence("fsync: \(Self.errnoString(errno))")
        }
    }

    private static func unlinkQuiet(_ path: String) {
        _ = unlink(path)
    }

    private static func errnoString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
