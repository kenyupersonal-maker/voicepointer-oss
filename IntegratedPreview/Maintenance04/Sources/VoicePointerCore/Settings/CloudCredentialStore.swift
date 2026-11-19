import Foundation
import CryptoKit
import Darwin

public enum CloudCredentialProvider: String, Sendable, Codable {
    case groq
    case aliyunBeijing = "aliyun-beijing"
    case openai
    case siliconflow

    var fileName: String {
        switch self {
        case .groq: return "cred-groq.bin"
        case .aliyunBeijing: return "cred-aliyun-beijing.bin"
        case .openai: return "cred-openai.bin"
        case .siliconflow: return "cred-siliconflow.bin"
        }
    }

    static var allCases: [CloudCredentialProvider] { [.groq, .aliyunBeijing, .openai, .siliconflow] }
}

public enum CredentialError: Error, Sendable, LocalizedError {
    case invalidKey
    case storage
    case corrupt
    case missing

    public var errorDescription: String? {
        switch self {
        case .missing:
            return "请在设置中保存 API Key"
        case .corrupt:
            return "本地密钥文件损坏，请重新配置"
        case .invalidKey, .storage:
            return "无法读取或保存本地密钥"
        }
    }
}

public actor CloudCredentialStore {
    /// Ciphertext only, memory-only and deliberately opaque to reflection/logging.
    public final class SetupCheckpoint: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        fileprivate let provider: CloudCredentialProvider
        fileprivate let cipher: Data?
        fileprivate let directoryExisted: Bool
        fileprivate let masterExisted: Bool
        fileprivate let lockExisted: Bool
        fileprivate let owner: UUID
        // Written by the owning store actor before atomic rename, including the failure path.
        fileprivate var attemptRevision: String?
        fileprivate init(provider: CloudCredentialProvider, cipher: Data?, directoryExisted: Bool,
                         masterExisted: Bool, lockExisted: Bool, owner: UUID) {
            self.provider = provider; self.cipher = cipher; self.directoryExisted = directoryExisted
            self.masterExisted = masterExisted; self.lockExisted = lockExisted; self.owner = owner
        }
        public var description: String { "CloudCredentialCheckpoint" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    private let service: String
    private let directory: URL?
    private let setupOwner = UUID()
    private let recoveryDirectory: URL?
    private var failSetupAfterRename = false
    private var failRemovalAfterRename = false
    @_spi(Testing) public func injectSetupFailureAfterRename(_ value: Bool) { failSetupAfterRename = value }
    @_spi(Testing) public func injectRemovalFailureAfterRename(_ value: Bool) { failRemovalAfterRename = value }

    public init(service: String = "com.voicenative.compare.cloud", directory: URL? = nil, recoveryDirectory: URL? = nil) {
        self.service = service
        self.directory = directory
        self.recoveryDirectory = recoveryDirectory
    }

    // MARK: - Path resolution

    private func storageDirectoryURL() throws -> URL {
        if let directory { return directory }
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent("com.kenyu.voicepointer.mac/LocalCredentials-v1", isDirectory: true)
    }

    private func sanitizedServiceComponent() throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !service.isEmpty,
              service.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw CredentialError.storage }
        return service
    }

    // MARK: - Validation

    nonisolated public static func validatedKey(_ key: String) throws -> Data {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...4096).contains(trimmed.count) else { throw CredentialError.invalidKey }
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw CredentialError.invalidKey
        }
        guard let data = trimmed.data(using: .ascii, allowLossyConversion: false) else {
            throw CredentialError.invalidKey
        }
        return data
    }

    // MARK: - Public API

    public func save(_ key: String, provider: CloudCredentialProvider) throws {
        var keyData = try Self.validatedKey(key)
        defer { keyData.resetBytes(in: 0..<keyData.count); keyData.removeAll() }
        try saveData(keyData, provider: provider)
    }
    private func saveData(_ keyData: Data, provider: CloudCredentialProvider) throws {
        guard (16...4096).contains(keyData.count), keyData.allSatisfy({ (33...126).contains($0) }) else { throw CredentialError.invalidKey }
        _ = try sanitizedServiceComponent()
        let dirfd = try openDirfd(create: true)
        defer { close(dirfd) }

        let lockFD = try openLockFile(dirfd: dirfd)
        defer { close(lockFD) }
        try acquireFlock(lockFD)
        defer { flock(lockFD, LOCK_UN) }

        // Reject any non-regular / wrong-owner / world-readable existing cipher target.
        try validateExistingFileForOverwrite(dirfd: dirfd, name: provider.fileName, maxBytes: 8192)

        let master = try ensureMasterKey(dirfd: dirfd)
        let cipher = try encrypt(keyData, provider: provider, master: master)
        try atomicWrite(data: cipher, dirfd: dirfd, name: provider.fileName)
    }

    /// Non-secret hash of the encrypted file. No master-key read or decryption.
    public func storedRevision(provider: CloudCredentialProvider) throws -> String? {
        let fd: Int32
        do { fd = try openDirfd(create: false) } catch CredentialError.missing { return nil }
        defer { close(fd) }
        guard let cipher = try readCipher(dirfd: fd, name: provider.fileName) else { return nil }
        return Self.cipherRevision(cipher)
    }
    public func setupCheckpoint(provider: CloudCredentialProvider) throws -> SetupCheckpoint {
        let fd: Int32
        do { fd = try openDirfd(create: false) }
        catch CredentialError.missing { return .init(provider: provider, cipher: nil, directoryExisted: false, masterExisted: false, lockExisted: false, owner: setupOwner) }
        defer { close(fd) }
        var st = stat()
        let master = fstatat(fd, "master.key", &st, AT_SYMLINK_NOFOLLOW) == 0
        let hadLock = fstatat(fd, "store.lock", &st, AT_SYMLINK_NOFOLLOW) == 0
        let lock = try openLockFile(dirfd: fd)
        defer { close(lock) }; try acquireFlock(lock); defer { flock(lock, LOCK_UN) }
        return .init(provider: provider, cipher: try readCipher(dirfd: fd, name: provider.fileName), directoryExisted: true, masterExisted: master, lockExisted: hadLock, owner: setupOwner)
    }
    public func saveForSetup(_ draft: OnlineAPIDraftKey, checkpoint: SetupCheckpoint) throws -> String {
        guard checkpoint.owner == setupOwner else { throw CredentialError.storage }
        var bytes = try draft.copyForPipe()
        defer { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll() }
        let fd = try openDirfd(create: true); defer { close(fd) }
        let lock = try openLockFile(dirfd: fd); defer { close(lock) }
        try acquireFlock(lock); defer { flock(lock, LOCK_UN) }
        guard try readCipher(dirfd: fd, name: checkpoint.provider.fileName) == checkpoint.cipher else { throw CredentialError.storage }
        guard (16...4096).contains(bytes.count), bytes.allSatisfy({ (33...126).contains($0) }) else { throw CredentialError.invalidKey }
        try validateExistingFileForOverwrite(dirfd: fd, name: checkpoint.provider.fileName, maxBytes: 8192)
        let master = try ensureMasterKey(dirfd: fd)
        let cipher = try encrypt(bytes, provider: checkpoint.provider, master: master)
        checkpoint.attemptRevision = Self.cipherRevision(cipher)
        try atomicWrite(data: cipher, dirfd: fd, name: checkpoint.provider.fileName, failAfterRename: failSetupAfterRename)
        return Self.cipherRevision(cipher)
    }
    /// Refuses to overwrite another completed writer. Rollback never decrypts a key.
    public func restoreSetup(_ checkpoint: SetupCheckpoint, expectedRevision: String?) throws {
        guard checkpoint.owner == setupOwner else { throw CredentialError.storage }
        let fd: Int32
        do { fd = try openDirfd(create: false) } catch CredentialError.missing {
            guard !checkpoint.directoryExisted else { throw CredentialError.storage }; return
        }
        defer { close(fd) }
        let lock = try openLockFile(dirfd: fd); defer { close(lock) }
        try acquireFlock(lock); defer { flock(lock, LOCK_UN) }
        let current = try readCipher(dirfd: fd, name: checkpoint.provider.fileName)
        if current != checkpoint.cipher {
            guard let revision = expectedRevision ?? checkpoint.attemptRevision,
                  current.map(Self.cipherRevision) == revision else { throw CredentialError.storage }
            if let cipher = checkpoint.cipher { try atomicWrite(data: cipher, dirfd: fd, name: checkpoint.provider.fileName) }
            else if current != nil { try moveToRecovery(dirfd: fd, name: checkpoint.provider.fileName) }
        }
        var hasOtherCipher = false
        for provider in CloudCredentialProvider.allCases {
            var st = stat()
            if fstatat(fd, provider.fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 { hasOtherCipher = true }
            else if errno != ENOENT { throw CredentialError.storage }
        }
        if !checkpoint.masterExisted && !hasOtherCipher {
            var st = stat()
            if fstatat(fd, "master.key", &st, AT_SYMLINK_NOFOLLOW) == 0 { try moveToRecovery(dirfd: fd, name: "master.key") }
            else if errno != ENOENT { throw CredentialError.storage }
        }
        // Keep this inode permanently: another process may already be waiting on its flock.
        guard fsync(fd) == 0 else { throw CredentialError.storage }
    }
    private func moveToRecovery(dirfd: Int32, name: String, failAfterRename: Bool = false) throws {
        let root = try recoveryDirectory ?? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = root.appendingPathComponent("VoicePointer-Setup-Rollback-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw CredentialError.storage }; defer { close(destination) }
        guard renameat(dirfd, name, destination, name) == 0 else { throw CredentialError.storage }
        guard !failAfterRename, fsync(destination) == 0 else { throw CredentialError.storage }
    }
    private static func cipherRevision(_ cipher: Data) -> String {
        SHA256.hash(data: cipher).map { String(format: "%02x", $0) }.joined()
    }
    /// User-confirmed removal, reversible. The shared master and stable lock stay in place.
    public func trashCredential(provider: CloudCredentialProvider, expectedRevision: String) throws {
        let fd = try openDirfd(create: false); defer { close(fd) }
        let lock = try openLockFile(dirfd: fd); defer { close(lock) }
        try acquireFlock(lock); defer { flock(lock, LOCK_UN) }
        guard let cipher = try readCipher(dirfd: fd, name: provider.fileName), Self.cipherRevision(cipher) == expectedRevision else { throw CredentialError.storage }
        do {
            try moveToRecovery(dirfd: fd, name: provider.fileName, failAfterRename: failRemovalAfterRename)
            guard fsync(fd) == 0 else { throw CredentialError.storage }
        } catch {
            // The same stable flock is still held. A move/fsync failure may have removed the
            // active slot, so restore its original ciphertext before releasing the lock.
            if try readCipher(dirfd: fd, name: provider.fileName) == nil {
                try atomicWrite(data: cipher, dirfd: fd, name: provider.fileName)
            }
            throw error
        }
    }

    public func isSaved(provider: CloudCredentialProvider) throws -> Bool {
        _ = try sanitizedServiceComponent()
        let dirfd: Int32
        do {
            dirfd = try openDirfd(create: false)
        } catch CredentialError.missing {
            return false
        }
        defer { close(dirfd) }

        let lockFD = try openLockFile(dirfd: dirfd)
        defer { close(lockFD) }
        try acquireFlock(lockFD)
        defer { flock(lockFD, LOCK_UN) }

        guard let cipher = try readCipher(dirfd: dirfd, name: provider.fileName) else {
            return false
        }
        let master = try loadMasterKey(dirfd: dirfd)
        _ = try decrypt(cipher, provider: provider, master: master)
        return true
    }

    /// T4 health check: attributes only. Does not read cipher/master bytes, decrypt, create a lock, or validate a Key.
    public func hasStoredCredentialFile(provider: CloudCredentialProvider) throws -> Bool {
        _ = try sanitizedServiceComponent()
        let dirfd: Int32
        do { dirfd = try openDirfd(create: false) } catch CredentialError.missing { return false }
        defer { close(dirfd) }
        var info = stat()
        guard fstatat(dirfd, provider.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw CredentialError.storage
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 8192 else { throw CredentialError.corrupt }
        return true
    }

    /// Non-secret revision for binding cloud permission to this exact encrypted
    /// credential file. AES-GCM uses a new nonce on every save, so replacing or
    /// re-saving a Key cannot inherit an earlier quota confirmation.
    public func credentialRevision(provider: CloudCredentialProvider) throws -> String? {
        _ = try sanitizedServiceComponent()
        let dirfd: Int32
        do {
            dirfd = try openDirfd(create: false)
        } catch CredentialError.missing {
            return nil
        }
        defer { close(dirfd) }

        let lockFD = try openLockFile(dirfd: dirfd)
        defer { close(lockFD) }
        try acquireFlock(lockFD)
        defer { flock(lockFD, LOCK_UN) }

        guard let cipher = try readCipher(dirfd: dirfd, name: provider.fileName) else {
            return nil
        }
        let master = try loadMasterKey(dirfd: dirfd)
        _ = try decrypt(cipher, provider: provider, master: master)
        return SHA256.hash(data: cipher).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes one provider's encrypted key. A key that is not there counts as removed, so calling it twice
    /// is harmless. Once no provider has a key left the master key goes too: it protects nothing then.
    /// When the master key itself cannot be read back (damaged or missing) every stored key is undecryptable,
    /// so they all go with it; that is what lets the next save start clean instead of failing for good.
    public func remove(provider: CloudCredentialProvider) throws {
        _ = try sanitizedServiceComponent()
        let dirfd: Int32
        do {
            dirfd = try openDirfd(create: false)
        } catch CredentialError.missing {
            return
        }
        defer { close(dirfd) }

        let lockFD = try openLockFile(dirfd: dirfd)
        defer { close(lockFD) }
        try acquireFlock(lockFD)
        defer { flock(lockFD, LOCK_UN) }

        if unlinkat(dirfd, provider.fileName, 0) != 0 {
            guard errno == ENOENT else { throw CredentialError.storage }
        }
        if !masterKeyIsReadable(dirfd: dirfd) {
            for other in CloudCredentialProvider.allCases where other != provider {
                if unlinkat(dirfd, other.fileName, 0) != 0 {
                    guard errno == ENOENT else { throw CredentialError.storage }
                }
            }
            if unlinkat(dirfd, "master.key", 0) != 0 {
                guard errno == ENOENT else { throw CredentialError.storage }
            }
            if fsync(dirfd) != 0 { throw CredentialError.storage }
            return
        }
        var st = stat()
        for other in CloudCredentialProvider.allCases {
            if fstatat(dirfd, other.fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                if fsync(dirfd) != 0 { throw CredentialError.storage }
                return
            }
            guard errno == ENOENT else { throw CredentialError.storage }
        }
        if unlinkat(dirfd, "master.key", 0) != 0 {
            guard errno == ENOENT else { throw CredentialError.storage }
        }
        if fsync(dirfd) != 0 { throw CredentialError.storage }
    }

    public func readForPipe(provider: CloudCredentialProvider, expectedRevision: String? = nil) throws -> Data {
        _ = try sanitizedServiceComponent()
        let dirfd = try openDirfd(create: false)
        defer { close(dirfd) }

        let lockFD = try openLockFile(dirfd: dirfd)
        defer { close(lockFD) }
        try acquireFlock(lockFD)
        defer { flock(lockFD, LOCK_UN) }

        guard let cipher = try readCipher(dirfd: dirfd, name: provider.fileName) else {
            throw CredentialError.missing
        }
        if let expectedRevision, Self.cipherRevision(cipher) != expectedRevision { throw CredentialError.missing }
        let master = try loadMasterKey(dirfd: dirfd)
        return try decrypt(cipher, provider: provider, master: master)
    }

    // MARK: - Crypto

    private func encrypt(_ plaintext: Data, provider: CloudCredentialProvider, master: Data) throws -> Data {
        let key = SymmetricKey(data: master)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad(provider: provider))
            guard let combined = sealed.combined else { throw CredentialError.storage }
            return combined
        } catch CredentialError.storage {
            throw CredentialError.storage
        } catch {
            throw CredentialError.corrupt
        }
    }

    private func decrypt(_ combined: Data, provider: CloudCredentialProvider, master: Data) throws -> Data {
        let key = SymmetricKey(data: master)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: aad(provider: provider))
        } catch {
            throw CredentialError.corrupt
        }
    }

    private func aad(provider: CloudCredentialProvider) -> Data {
        Data("\(service)|\(provider.rawValue)".utf8)
    }

    // MARK: - Master key

    private func ensureMasterKey(dirfd: Int32) throws -> Data {
        let fd = openat(dirfd, "master.key", O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        if fd >= 0 {
            defer { close(fd) }
            guard try fstatIsRegularPrivate(fd, maxBytes: 128) else { throw CredentialError.storage }
            let data = try readAll(fd: fd, maxBytes: 128)
            guard data.count == 32 else { throw CredentialError.corrupt }
            return data
        }
        guard errno == ENOENT else { throw CredentialError.storage }
        // Only generate if no ciphertext exists (never recreate over existing credentials).
        var st = stat()
        for provider in CloudCredentialProvider.allCases {
            if fstatat(dirfd, provider.fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 { throw CredentialError.storage }
            guard errno == ENOENT else { throw CredentialError.storage }
        }
        let master = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try atomicWrite(data: master, dirfd: dirfd, name: "master.key")
        return master
    }

    /// Whether `master.key` is there, private and the right size, i.e. whether `loadMasterKey` would succeed.
    private func masterKeyIsReadable(dirfd: Int32) -> Bool {
        let fd = openat(dirfd, "master.key", O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard (try? fstatIsRegularPrivate(fd, maxBytes: 128)) == true,
              let data = try? readAll(fd: fd, maxBytes: 128) else { return false }
        return data.count == 32
    }

    private func loadMasterKey(dirfd: Int32) throws -> Data {
        let fd = openat(dirfd, "master.key", O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else {
            if errno == ENOENT { throw CredentialError.missing }
            throw CredentialError.storage
        }
        defer { close(fd) }
        guard try fstatIsRegularPrivate(fd, maxBytes: 128) else { throw CredentialError.storage }
        let data = try readAll(fd: fd, maxBytes: 128)
        guard data.count == 32 else { throw CredentialError.corrupt }
        return data
    }

    // MARK: - Filesystem helpers

    private func openDirfd(create: Bool) throws -> Int32 {
        let dir = try storageDirectoryURL()
        let path = dir.path
        var st = stat()
        if lstat(path, &st) != 0 {
            guard create else { throw CredentialError.missing }
            do {
                try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw CredentialError.storage }
            } catch {
                // Another store may have created it; validate the opened directory below.
                guard lstat(path, &st) == 0 else { throw CredentialError.storage }
            }
            // mkdir race: if EEXIST, fall through and validate via open + fstat.
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if !create && errno == ENOENT { throw CredentialError.missing }
            throw CredentialError.storage
        }
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw CredentialError.storage
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw CredentialError.storage
        }
        guard st.st_uid == getuid() else {
            close(fd)
            throw CredentialError.storage
        }
        guard (st.st_mode & 0o777) == 0o700 else {
            close(fd)
            throw CredentialError.storage
        }
        return fd
    }

    private func validateExistingFileForOverwrite(dirfd: Int32, name: String, maxBytes: Int) throws {
        var st = stat()
        if fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw CredentialError.storage }
            guard st.st_uid == getuid() else { throw CredentialError.storage }
            guard (st.st_mode & 0o077) == 0 else { throw CredentialError.storage }
            guard st.st_size <= maxBytes else { throw CredentialError.storage }
        } else if errno != ENOENT {
            throw CredentialError.storage
        }
    }

    private func openLockFile(dirfd: Int32) throws -> Int32 {
        let maxAttempts = 3
        var lastError: Int32 = 0
    
        for _ in 0..<maxAttempts {
            // 1) Try opening an existing lock file.
            let existing = openat(dirfd, "store.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if existing >= 0 {
                do {
                    guard try fstatIsRegularPrivate(existing, maxBytes: 1_048_576) else { throw CredentialError.storage }
                    return existing
                } catch {
                    close(existing)
                    throw error
                }
            }
    
            lastError = errno
            if lastError != ENOENT && lastError != EEXIST {
                throw CredentialError.storage
            }
    
            // 2) Create it exclusively; avoids racy combined create/open.
            let created = openat(dirfd, "store.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            if created >= 0 {
                do {
                    guard try fstatIsRegularPrivate(created, maxBytes: 1_048_576) else { throw CredentialError.storage }
                    return created
                } catch {
                    close(created)
                    throw error
                }
            }
    
            lastError = errno
            if lastError != EEXIST && lastError != ENOENT {
                throw CredentialError.storage
            }
    
            // EEXIST or transient ENOENT: loop and retry the open-existing path.
        }
    
        _ = lastError
        throw CredentialError.storage
    }

    private func acquireFlock(_ fd: Int32) throws {
        guard flock(fd, LOCK_EX) == 0 else { throw CredentialError.storage }
    }

    private func fstatIsRegularPrivate(_ fd: Int32, maxBytes: Int) throws -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CredentialError.storage }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
        guard st.st_uid == getuid() else { return false }
        guard (st.st_mode & 0o077) == 0 else { return false }
        guard st.st_size <= maxBytes else { return false }
        return true
    }

    private func readCipher(dirfd: Int32, name: String) throws -> Data? {
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CredentialError.storage
        }
        defer { close(fd) }
        guard try fstatIsRegularPrivate(fd, maxBytes: 8192) else { throw CredentialError.storage }
        return try readAll(fd: fd, maxBytes: 8192)
    }

    private func readAll(fd: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw CredentialError.storage }
            if n == 0 { break }
            data.append(buf, count: n)
            if data.count > maxBytes { throw CredentialError.storage }
        }
        return data
    }

    private func atomicWrite(data: Data, dirfd: Int32, name: String, failAfterRename: Bool = false) throws {
        let unique = "tmp-\(getpid())-\(UInt64.random(in: 0...UInt64.max))"
        let fd = openat(dirfd, unique, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CredentialError.storage }
        var writeOK = true
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n <= 0 { throw CredentialError.storage }
                    offset += n
                }
            }
            if fsync(fd) != 0 { throw CredentialError.storage }
        } catch {
            writeOK = false
        }
        close(fd)
        if !writeOK {
            _ = unlinkat(dirfd, unique, 0)
            throw CredentialError.storage
        }
        if renameat(dirfd, unique, dirfd, name) != 0 {
            _ = unlinkat(dirfd, unique, 0)
            throw CredentialError.storage
        }
        if failAfterRename { throw CredentialError.storage }
        if fsync(dirfd) != 0 { throw CredentialError.storage }
    }
}
