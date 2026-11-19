import Foundation
import Darwin

internal enum DuplexLineError: Error {
    case invalid
    case closed
    case busy
    case timeout
    case io
    case oversize
}

/// Pure local pipe transport over a duplicated pair of file descriptors.
/// Line-oriented: messages are LF-terminated, max payload 1 MiB.
/// No Process, network, keychain, or logging. Caller owns lifecycle:
/// read/write timeouts never close the descriptors.
internal actor DuplexLineIO {

    private static let maxPayload = 1_048_576            // 1 MiB payload cap
    private static let maxBuffer  = 1_048_576 + 8_192   // pending cap without LF
    private static let chunk      = 8_192

    private var readFD: Int32
    private var writeFD: Int32
    private var closedFlag = false
    private var reading = false
    private var writing = false
    private var pendingData = [UInt8]()

    /// Duplicates both descriptors so this instance owns its copies.
    /// Originals are never closed here. Raises `invalid` on bad FDs;
    /// on any failure, owned duplicates are closed before throwing.
    internal init(readFD: Int32, writeFD: Int32) throws {
        guard readFD >= 0, writeFD >= 0, readFD != writeFD else {
            throw DuplexLineError.invalid
        }

        let dupRead = dup(readFD)
        if dupRead < 0 { throw DuplexLineError.invalid }

        let ownedRead = dupRead
        var ownedWrite: Int32 = -1
        do {
            let dupWrite = dup(writeFD)
            if dupWrite < 0 { throw DuplexLineError.invalid }
            ownedWrite = dupWrite

            // Close-on-exec so children never inherit the transport.
            if fcntl(ownedRead, F_SETFD, FD_CLOEXEC) < 0 { throw DuplexLineError.io }
            if fcntl(ownedWrite, F_SETFD, FD_CLOEXEC) < 0 { throw DuplexLineError.io }

            for fd in [ownedRead, ownedWrite] {
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DuplexLineError.io }
            }

            // Avoid SIGPIPE on write to a dead peer.
            if fcntl(ownedWrite, F_SETNOSIGPIPE, 1) < 0 { throw DuplexLineError.io }
        } catch {
            Darwin.close(ownedRead)
            if ownedWrite >= 0 { Darwin.close(ownedWrite) }
            throw error
        }

        // Note: O_NONBLOCK on the originals applies to the shared open
        // file description and is intentionally inherited by the dup.
        self.readFD = ownedRead
        self.writeFD = ownedWrite
    }

    deinit {
        if readFD >= 0 { Darwin.close(readFD) }
        if writeFD >= 0 { Darwin.close(writeFD) }
    }

    /// Idempotent synchronous close of owned duplicates only.
    internal func close() {
        if closedFlag { return }
        closedFlag = true
        if readFD >= 0 { Darwin.close(readFD); readFD = -1 }
        if writeFD >= 0 { Darwin.close(writeFD); writeFD = -1 }
        pendingData.removeAll(keepingCapacity: false)
    }

    private var isClosed: Bool { closedFlag || readFD < 0 || writeFD < 0 }

    /// Reads one LF-terminated line (payload excludes LF), max 1 MiB.
    /// Timeout does NOT close the descriptors; caller owns lifecycle.
    internal func readLine(timeout: TimeInterval) async throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 360 else {
            throw DuplexLineError.invalid
        }
        guard !reading else { throw DuplexLineError.busy }
        reading = true
        defer { reading = false }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var scanOffset = 0

        while true {
            try Task.checkCancellation()
            if isClosed { throw DuplexLineError.closed }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw DuplexLineError.timeout
            }

            if let idx = pendingData[scanOffset...].firstIndex(of: 0x0A) {
                guard idx <= DuplexLineIO.maxPayload else {
                    throw DuplexLineError.oversize
                }
                let line = Data(pendingData[0..<idx])
                pendingData.removeSubrange(0...idx)
                return line
            }
            scanOffset = pendingData.count

            if pendingData.count > DuplexLineIO.maxBuffer {
                throw DuplexLineError.oversize
            }

            var buf = [UInt8](repeating: 0, count: DuplexLineIO.chunk)
            let fd = readFD
            if fd < 0 || closedFlag { throw DuplexLineError.closed }
            let n = read(fd, &buf, DuplexLineIO.chunk)

            if n > 0 {
                guard pendingData.count + n <= Self.maxBuffer else { throw DuplexLineError.oversize }
                pendingData.reserveCapacity(pendingData.count + n)
                pendingData.append(contentsOf: buf[0..<Int(n)])
            } else if n == 0 {
                throw DuplexLineError.closed
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                throw DuplexLineError.io
            }
        }
    }

    /// Writes one line: payload of 1...1_048_577 bytes whose last byte is LF
    /// with no embedded LF. Exactly one concurrent read + one write allowed.
    internal func writeLine(_ data: Data, timeout: TimeInterval) async throws {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else {
            throw DuplexLineError.invalid
        }
        guard data.count >= 1, data.count <= 1_048_577 else {
            throw DuplexLineError.oversize
        }
        let bytes = [UInt8](data)
        guard bytes[bytes.count - 1] == 0x0A else { throw DuplexLineError.invalid }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x0A {
            throw DuplexLineError.invalid
        }

        guard !writing else { throw DuplexLineError.busy }
        writing = true
        defer { writing = false }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var offset = 0

        while offset < bytes.count {
            try Task.checkCancellation()
            if isClosed { throw DuplexLineError.closed }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw DuplexLineError.timeout
            }

            let fd = writeFD
            if fd < 0 || closedFlag { throw DuplexLineError.closed }
            let n = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }

            if n > 0 {
                offset += Int(n)
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else if n == 0 {
                throw DuplexLineError.io
            } else {
                throw DuplexLineError.io
            }
        }
    }
}
