import CryptoKit
import Darwin
import Foundation

/// Stable, non-secret identity for one provider account and model configuration.
/// `accountReference` must be an opaque local reference, never an API key.
public struct CloudAdmissionIdentity: Hashable, Sendable {
    public let provider: String
    public let accountReference: String
    /// Opaque revision of the encrypted local credential. Re-saving a Key
    /// creates a different revision and cannot inherit an older confirmation.
    public let credentialRevision: String
    public let region: String
    public let workspace: String
    public let modelID: String

    public init(
        provider: String,
        accountReference: String,
        credentialRevision: String,
        region: String,
        workspace: String,
        modelID: String
    ) throws {
        let fields = [provider, accountReference, credentialRevision, region, workspace, modelID]
        guard fields.allSatisfy(Self.isValidIdentityComponent) else {
            throw CloudAdmissionIdentityError.invalidComponent
        }
        self.provider = provider
        self.accountReference = accountReference
        self.credentialRevision = credentialRevision
        self.region = region
        self.workspace = workspace
        self.modelID = modelID
    }

    var persistenceIdentifier: String {
        var data = Data("VoicePointer.CloudAdmission.Identity.v1".utf8)
        for field in [provider, accountReference, credentialRevision, region, workspace, modelID] {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidIdentityComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public enum CloudAdmissionIdentityError: Error, Sendable {
    case invalidComponent
}

public enum CloudAdmissionPolicy: String, Codable, Sendable {
    case disabled
    case freeOnly
}

/// There is deliberately no API in this gate that records `providerVerified`.
/// A future verifier must supply independently verified evidence before that state can admit.
public enum CloudGuardEvidence: String, Codable, Sendable {
    case unknown
    case userConfirmed
    case providerVerified
}

public enum CloudAdmissionPauseReason: String, Codable, Sendable {
    case freeQuotaExhausted
    case accountBalanceBlocked
}

public struct CloudAdmissionStateSnapshot: Sendable, Equatable {
    public let policy: CloudAdmissionPolicy
    public let guardEvidence: CloudGuardEvidence
    public let guardObservedAt: Date?
    public let verificationRevision: String?
    public let pauseReason: CloudAdmissionPauseReason?
    public let pauseEpoch: UInt64
    public let resumeRequestedAt: Date?
    public let stateRevision: UUID

    init(
        policy: CloudAdmissionPolicy = .disabled,
        guardEvidence: CloudGuardEvidence = .unknown,
        guardObservedAt: Date? = nil,
        verificationRevision: String? = nil,
        pauseReason: CloudAdmissionPauseReason? = nil,
        pauseEpoch: UInt64 = 0,
        resumeRequestedAt: Date? = nil,
        stateRevision: UUID = UUID()
    ) {
        self.policy = policy
        self.guardEvidence = guardEvidence
        self.guardObservedAt = guardObservedAt
        self.verificationRevision = verificationRevision
        self.pauseReason = pauseReason
        self.pauseEpoch = pauseEpoch
        self.resumeRequestedAt = resumeRequestedAt
        self.stateRevision = stateRevision
    }

    static let failClosed = CloudAdmissionStateSnapshot()
}

public enum CloudAdmissionStorageError: Error, Sendable {
    case malformed
    case symlink
    case invalidPath
    case persistence(String)
}

/// Separate, credential-free persistent state for T23 cloud admission.
/// The file contains identity fingerprints, policy and safety evidence only.
public final class CloudAdmissionStateStore: @unchecked Sendable {
    private static let schemaVersion = 1
    private static let maximumFileBytes = 1_048_576

    private let fileURL: URL
    // Gate instances in this process may share one state file.
    private static let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return support
            .appendingPathComponent("com.kenyu.voicepointer.mac", isDirectory: true)
            .appendingPathComponent("CloudAdmission-v1", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func load(for identity: CloudAdmissionIdentity) throws -> CloudAdmissionStateSnapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let document = try readDocument()
        return document.identities[identity.persistenceIdentifier]?.snapshot ?? .failClosed
    }

    /// Serializes read-modify-write across gate instances in this process.
    func transact<Value>(
        for identity: CloudAdmissionIdentity,
        _ update: (CloudAdmissionStateSnapshot) -> (CloudAdmissionStateSnapshot, Value, Bool)
    ) throws -> (CloudAdmissionStateSnapshot, Value) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var document = try readDocument()
        let key = identity.persistenceIdentifier
        let current = document.identities[key]?.snapshot ?? .failClosed
        let (next, result, shouldPersist) = update(current)
        if shouldPersist {
            document.identities[key] = PersistedCloudAdmissionState(snapshot: next)
            try writeDocument(document)
        }
        return (next, result)
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var identities: [String: PersistedCloudAdmissionState]
    }

    private struct PersistedCloudAdmissionState: Codable {
        let policy: CloudAdmissionPolicy
        let guardEvidence: CloudGuardEvidence
        let guardObservedAt: Date?
        let verificationRevision: String?
        let pauseReason: CloudAdmissionPauseReason?
        let pauseEpoch: UInt64
        let resumeRequestedAt: Date?
        let stateRevision: UUID

        init(snapshot: CloudAdmissionStateSnapshot) {
            policy = snapshot.policy
            guardEvidence = snapshot.guardEvidence
            guardObservedAt = snapshot.guardObservedAt
            verificationRevision = snapshot.verificationRevision
            pauseReason = snapshot.pauseReason
            pauseEpoch = snapshot.pauseEpoch
            resumeRequestedAt = snapshot.resumeRequestedAt
            stateRevision = snapshot.stateRevision
        }

        var snapshot: CloudAdmissionStateSnapshot {
            CloudAdmissionStateSnapshot(
                policy: policy,
                guardEvidence: guardEvidence,
                guardObservedAt: guardObservedAt,
                verificationRevision: verificationRevision,
                pauseReason: pauseReason,
                pauseEpoch: pauseEpoch,
                resumeRequestedAt: resumeRequestedAt,
                stateRevision: stateRevision
            )
        }
    }

    private func readDocument() throws -> Document {
        guard let data = try readFileIfPresent() else {
            return Document(schemaVersion: Self.schemaVersion, identities: [:])
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == Self.schemaVersion,
              document.identities.count <= 4096,
              document.identities.keys.allSatisfy(Self.isFingerprint) else {
            throw CloudAdmissionStorageError.malformed
        }
        return document
    }

    private func readFileIfPresent() throws -> Data? {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw CloudAdmissionStorageError.persistence("lstat: \(Self.errnoString(errno))")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw CloudAdmissionStorageError.symlink }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumFileBytes else {
            throw CloudAdmissionStorageError.malformed
        }

        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { throw CloudAdmissionStorageError.persistence("open: \(Self.errnoString(errno))") }
        defer { close(fd) }
        var openedInfo = stat()
        guard fstat(fd, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_size >= 0,
              openedInfo.st_size <= Self.maximumFileBytes else {
            throw CloudAdmissionStorageError.malformed
        }
        return try Self.readFully(fd: fd, byteCount: Int(openedInfo.st_size))
    }

    private func writeDocument(_ document: Document) throws {
        guard document.schemaVersion == Self.schemaVersion else { throw CloudAdmissionStorageError.malformed }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw CloudAdmissionStorageError.persistence("encode failed")
        }
        guard data.count <= Self.maximumFileBytes else { throw CloudAdmissionStorageError.malformed }

        let directory = fileURL.deletingLastPathComponent()
        try Self.ensureDirectory(directory)
        let tempURL = directory.appendingPathComponent(".state.\(UUID().uuidString).tmp", isDirectory: false)
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CloudAdmissionStorageError.persistence("open temp: \(Self.errnoString(errno))") }
        var closed = false
        do {
            try Self.writeFully(fd: fd, data: data)
            try Self.fsync(fd: fd)
            let closeResult = close(fd)
            closed = true
            guard closeResult == 0 else {
                throw CloudAdmissionStorageError.persistence("close: \(Self.errnoString(errno))")
            }
        } catch {
            if !closed { close(fd) }
            _ = unlink(tempURL.path)
            throw error
        }

        do { try Self.validateDestination(fileURL.path) }
        catch {
            _ = unlink(tempURL.path)
            throw error
        }
        guard rename(tempURL.path, fileURL.path) == 0 else {
            let message = Self.errnoString(errno)
            _ = unlink(tempURL.path)
            throw CloudAdmissionStorageError.persistence("rename: \(message)")
        }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
        guard directoryFD >= 0 else { throw CloudAdmissionStorageError.persistence("open dir: \(Self.errnoString(errno))") }
        defer { close(directoryFD) }
        try Self.fsync(fd: directoryFD)
    }

    private static func validateDestination(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw CloudAdmissionStorageError.symlink }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw CloudAdmissionStorageError.invalidPath }
            return
        }
        guard errno == ENOENT else {
            throw CloudAdmissionStorageError.persistence("lstat destination: \(errnoString(errno))")
        }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw CloudAdmissionStorageError.symlink }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CloudAdmissionStorageError.invalidPath }
            return
        }
        guard errno == ENOENT else { throw CloudAdmissionStorageError.persistence("lstat dir: \(errnoString(errno))") }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CloudAdmissionStorageError.persistence("mkdir failed")
        }
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & S_IFMT) != S_IFLNK else {
            throw CloudAdmissionStorageError.invalidPath
        }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func readFully(fd: Int32, byteCount: Int) throws -> Data {
        var result = Data(count: byteCount)
        try result.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < byteCount {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), byteCount - offset)
                if count > 0 { offset += count; continue }
                if count == 0 { throw CloudAdmissionStorageError.malformed }
                if errno == EINTR { continue }
                throw CloudAdmissionStorageError.persistence("read: \(errnoString(errno))")
            }
        }
        return result
    }

    private static func writeFully(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count == 0 { throw CloudAdmissionStorageError.persistence("zero-byte write") }
                if errno == EINTR { continue }
                throw CloudAdmissionStorageError.persistence("write: \(errnoString(errno))")
            }
        }
    }

    private static func fsync(fd: Int32) throws {
        while true {
            if Darwin.fsync(fd) == 0 { return }
            if errno == EINTR { continue }
            throw CloudAdmissionStorageError.persistence("fsync: \(errnoString(errno))")
        }
    }

    private static func errnoString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
