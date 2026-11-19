import Foundation
import Darwin

/// The lexicon's small private-file layer: a directory only this user can enter, a file only this user can
/// read, no symlinks anywhere on the path we touch, and writes that either complete or leave the old file.
enum LexiconFileIO {
    typealias Failure = LexiconStore.StoreError

    static func errnoText(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// What identifies one version of the file on disk. The same fingerprint on two looks means nothing but
    /// this process wrote in between; a different one means the file was changed from outside (a hand edit,
    /// a sync tool, a restore).
    struct Fingerprint: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ st: stat) {
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modifiedSeconds = Int64(st.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(st.st_mtimespec.tv_nsec)
        }
    }

    /// The fingerprint of whatever is at `url` right now (a symlink counts as itself); nil when nothing is there.
    static func fingerprint(of url: URL) throws -> Fingerprint? {
        guard let st = try lstatIfExists(url.path) else { return nil }
        return Fingerprint(st)
    }

    /// lstat without following a symlink; nil when nothing is there.
    static func lstatIfExists(_ path: String) throws -> stat? {
        var st = stat()
        if lstat(path, &st) == 0 { return st }
        if errno == ENOENT { return nil }
        throw Failure.unavailable("lstat: \(errnoText(errno))")
    }

    /// Checks (and, when `create` is set, creates) `directory` as a private directory owned by this user.
    /// Returns false when it does not exist and `create` is false.
    static func prepareDirectory(_ directory: URL, create: Bool) throws -> Bool {
        let path = directory.path
        if let existing = try lstatIfExists(path) {
            try verifyPrivateDirectory(existing, path: path)
            return true
        }
        guard create else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Failure.unavailable("mkdir: \(error.localizedDescription)")
        }
        guard let created = try lstatIfExists(path) else { throw Failure.unavailable("mkdir: directory vanished") }
        try verifyPrivateDirectory(created, path: path)
        return true
    }

    private static func verifyPrivateDirectory(_ st: stat, path: String) throws {
        if (st.st_mode & S_IFMT) == S_IFLNK { throw Failure.unavailable("symlink") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unavailable("not a directory") }
        guard st.st_uid == geteuid() else { throw Failure.unavailable("owner") }
        if (st.st_mode & 0o077) != 0, chmod(path, 0o700) != 0 {
            throw Failure.unavailable("chmod: \(errnoText(errno))")
        }
    }

    /// The file's bytes, or nil when it does not exist. A symlink, a non-regular file or a file owned by
    /// somebody else is refused; a file larger than `maxBytes` is reported as malformed.
    static func readFile(_ url: URL, maxBytes: Int) throws -> Data? {
        try readFileWithFingerprint(url, maxBytes: maxBytes)?.data
    }

    /// `readFile` together with the fingerprint of the exact file that was read.
    static func readFileWithFingerprint(_ url: URL, maxBytes: Int) throws -> (data: Data, fingerprint: Fingerprint)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure.unavailable("open: \(errnoText(errno))")
        }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure.unavailable("fstat: \(errnoText(errno))") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.unavailable("not a regular file") }
        guard st.st_uid == geteuid() else { throw Failure.unavailable("owner") }
        guard st.st_size <= Int64(maxBytes) else { throw Failure.malformed }
        if (st.st_mode & 0o077) != 0 { _ = fchmod(fd, 0o600) }
        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > maxBytes { throw Failure.malformed }
                continue
            }
            if count == 0 { return (data, Fingerprint(st)) }
            if errno == EINTR { continue }
            throw Failure.unavailable("read: \(errnoText(errno))")
        }
    }

    /// Writes `data` to `url` so that a crash leaves either the old file or the new one, never a mix.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        _ = try prepareDirectory(directory, create: true)
        if let existing = try lstatIfExists(url.path), (existing.st_mode & S_IFMT) != S_IFREG {
            throw Failure.unavailable("destination is not a regular file")
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable("open temporary: \(errnoText(errno))") }
        var closed = false
        do {
            try writeAll(fd, data)
            try syncFile(fd)
            let result = close(fd)
            closed = true
            if result != 0 { throw Failure.unavailable("close: \(errnoText(errno))") }
        } catch {
            if !closed { _ = close(fd) }
            _ = unlink(temporary)
            throw error
        }
        guard rename(temporary, url.path) == 0 else {
            let reason = errnoText(errno)
            _ = unlink(temporary)
            throw Failure.unavailable("rename: \(reason)")
        }
        syncDirectory(directory)
    }

    /// Renames `url` to a sibling name (a backup of a file we will not read again). Never overwrites.
    static func moveAside(_ url: URL, as newName: String) throws -> URL {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard let existing = try lstatIfExists(url.path), (existing.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.unavailable("nothing to move aside")
        }
        if try lstatIfExists(target.path) != nil { throw Failure.unavailable("backup name already exists") }
        guard rename(url.path, target.path) == 0 else {
            throw Failure.unavailable("rename: \(errnoText(errno))")
        }
        syncDirectory(url.deletingLastPathComponent())
        return target
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if written == 0 { throw Failure.unavailable("write: zero bytes") }
                if errno == EINTR { continue }
                throw Failure.unavailable("write: \(errnoText(errno))")
            }
        }
    }

    private static func syncFile(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw Failure.unavailable("fsync: \(errnoText(errno))")
        }
    }

    private static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        _ = close(fd)
    }
}
