import Foundation
@_spi(Testing) import VoicePointerCore

private actor HandshakeCapture {
    private(set) var key: Data?
    private(set) var calls = 0

    func record(_ key: Data) {
        self.key = key
        calls += 1
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private struct UnrelatedFailure: Error {}

/// The settings' connection test and the key removal behind "移除". Offline: a fake key source, fake handshakes
/// and a temporary credential directory. No network, no worker and no real key: the strings below that look like
/// keys are made up for the test.
enum CloudConnectionCheckChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let fakeKey = Data("sk-selftest-not-a-real-key-0000".utf8)

        // The handshake gets exactly the key that was read, and success is just "connected".
        let capture = HandshakeCapture()
        let connected = await CloudConnectionCheck.run(
            readKey: { fakeKey },
            handshake: { await capture.record($0) }
        )
        expect(connected == .connected, "a handshake that returns must read as connected")
        let handedKey = await capture.key
        let handshakeCalls = await capture.calls
        expect(handedKey == fakeKey && handshakeCalls == 1, "the handshake must run once with the key that was read")

        // A key that cannot be read never reaches the handshake.
        let keyErrors: [(CredentialError, CloudConnectionCheck.Failure)] = [
            (.missing, .noKey), (.corrupt, .keyUnreadable), (.storage, .keyUnreadable), (.invalidKey, .keyUnreadable),
        ]
        for (error, expected) in keyErrors {
            let unread = HandshakeCapture()
            let outcome = await CloudConnectionCheck.run(
                readKey: { throw error },
                handshake: { await unread.record($0) }
            )
            let unreadCalls = await unread.calls
            expect(outcome == .failed(expected), "a key read failing with \(error) must read as \(expected)")
            expect(unreadCalls == 0, "a key that cannot be read must never reach the handshake (\(error))")
        }

        // Every service failure has an explicit reading.
        let expectedByCode: [AliServiceFailure.Code: CloudConnectionCheck.Failure] = [
            .authFailed: .rejectedKey, .accessDenied: .noAccess, .freeQuotaExhausted: .freeQuotaExhausted,
            .balanceDue: .balanceDue, .rateLimited: .rateLimited, .modelUnavailable: .modelUnavailable,
            .serviceUnavailable: .serviceUnavailable, .networkFailed: .network, .timeout: .timeout,
            .invalidRequest: .unknown, .streamFailed: .unknown,
        ]
        expect(Set(expectedByCode.keys) == Set(AliServiceFailure.Code.allCases), "the fixture must cover every service failure code")
        for code in AliServiceFailure.Code.allCases {
            let outcome = await CloudConnectionCheck.run(
                readKey: { fakeKey },
                handshake: { _ in throw AliServiceFailure(code) }
            )
            expect(outcome == .failed(expectedByCode[code] ?? .unknown), "service failure \(code) must read as \(String(describing: expectedByCode[code]))")
        }

        // Transport and worker-side errors.
        let other: [(any Error, CloudConnectionCheck.Failure, String)] = [
            (URLError(.notConnectedToInternet), .network, "no internet"),
            (URLError(.cannotFindHost), .network, "no host"),
            (URLError(.timedOut), .timeout, "URL timeout"),
            (CloudConnectionCheck.HandshakeError.workerUnavailable, .worker, "worker unavailable"),
            (CloudConnectionCheck.HandshakeError.notClosed, .notClosed, "worker not closed"),
            (UnrelatedFailure(), .unknown, "an unrelated error"),
            (CancellationError(), .unknown, "a cancellation nobody asked for"),
        ]
        for (error, expected, label) in other {
            let outcome = await CloudConnectionCheck.run(readKey: { fakeKey }, handshake: { _ in throw error })
            expect(outcome == .failed(expected), "\(label) must read as \(expected)")
        }

        // A stuck handshake ends in a timeout promptly, and is told to stop.
        let stopped = CancellationFlag()
        let started = Date()
        let stuck = await CloudConnectionCheck.run(
            timeout: 0.2,
            readKey: { fakeKey },
            handshake: { _ in
                try await withTaskCancellationHandler {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } onCancel: {
                    stopped.set()
                }
            }
        )
        expect(stuck == .failed(.timeout), "a handshake that never answers must read as a timeout")
        expect(Date().timeIntervalSince(started) < 3, "the timeout must not wait for the stuck handshake to finish")
        var waited = 0
        while !stopped.isSet && waited < 100 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        expect(stopped.isSet, "a timed-out handshake must be cancelled so its worker is shut down")

        // A quick answer is not held back by the timer.
        let quickStart = Date()
        let quick = await CloudConnectionCheck.run(timeout: 10, readKey: { fakeKey }, handshake: { _ in })
        expect(quick == .connected && Date().timeIntervalSince(quickStart) < 2, "a quick handshake must return without waiting for the timeout")

        // Wording: every failure has its own plain sentence, none of them can quote a key or the service.
        var seen = Set<String>()
        for failure in CloudConnectionCheck.Failure.allCases {
            let message = failure.message
            expect(!message.isEmpty && message.hasSuffix("。"), "\(failure) must have a full-sentence message")
            expect(!message.contains("sk-") && !message.contains("Bearer"), "\(failure) message must not look like a key or a header")
            expect(seen.insert(message).inserted, "\(failure) must not repeat another failure's message")
        }
        expect(!CloudConnectionCheck.successMessage.isEmpty && !seen.contains(CloudConnectionCheck.successMessage), "the success message must be its own sentence")
        expect(CloudConnectionCheck.successMessage.contains("没有发送声音"), "the success message must say that no audio was sent")
        expect(
            CloudConnectionCheck.Outcome.connected.logLabel == "connected"
                && CloudConnectionCheck.Outcome.failed(.rejectedKey).logLabel == "failed.rejectedKey",
            "the log label must be the fixed vocabulary"
        )
        for address in [CloudEntry.consoleURL, CloudEntry.keyHelpURL] {
            let url = URL(string: address)
            expect(url?.scheme == "https" && (url?.host?.hasSuffix("aliyun.com") == true), "\(address) must be an https Aliyun address")
        }

        failures += await credentialRemovalChecks(fakeKey: fakeKey)
        return failures
    }

    /// `CloudCredentialStore.remove`: what "移除" does to the encrypted key file and the master key.
    private static func credentialRemovalChecks(fakeKey: Data) async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("CloudCredentialRemovalChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["temporary credential directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cred", isDirectory: true)
        let store = CloudCredentialStore(service: "svc-removal", directory: directory)
        let text = String(decoding: fakeKey, as: UTF8.self)
        let otherText = "gsk-selftest-not-a-real-key-1111"
        let masterPath = directory.appendingPathComponent("master.key").path

        do {
            // Nothing saved yet: removing is a harmless no-op.
            try await store.remove(provider: .aliyunBeijing)

            try await store.save(text, provider: .aliyunBeijing)
            expect(try await store.isSaved(provider: .aliyunBeijing), "a saved key must read as saved")
            let firstRevision = try await store.credentialRevision(provider: .aliyunBeijing)
            expect(firstRevision != nil, "a saved key must have a revision")

            try await store.remove(provider: .aliyunBeijing)
            expect(try await store.isSaved(provider: .aliyunBeijing) == false, "a removed key must read as not saved")
            expect(try await store.credentialRevision(provider: .aliyunBeijing) == nil, "a removed key must have no revision")
            do {
                _ = try await store.readForPipe(provider: .aliyunBeijing)
                expect(false, "a removed key must not be readable")
            } catch CredentialError.missing {
                // expected
            } catch {
                expect(false, "reading a removed key must fail as missing, not \(error)")
            }
            try await store.remove(provider: .aliyunBeijing)  // twice is fine
            expect(!FileManager.default.fileExists(atPath: masterPath), "with no key left the master key must go too")

            // A key saved again is a new key: it must not inherit the old revision.
            try await store.save(text, provider: .aliyunBeijing)
            let secondRevision = try await store.credentialRevision(provider: .aliyunBeijing)
            expect(secondRevision != nil && secondRevision != firstRevision, "re-saving after removal must give a new revision")
            expect(try await store.readForPipe(provider: .aliyunBeijing) == fakeKey, "a re-saved key must read back unchanged")

            // Removing one provider leaves the other, and the master key it needs.
            try await store.save(otherText, provider: .groq)
            try await store.remove(provider: .aliyunBeijing)
            expect(try await store.isSaved(provider: .aliyunBeijing) == false, "the removed provider must be gone")
            expect(
                try await store.readForPipe(provider: .groq) == Data(otherText.utf8),
                "the other provider's key must survive a removal"
            )
            expect(FileManager.default.fileExists(atPath: masterPath), "the master key must stay while another key still needs it")
            try await store.remove(provider: .groq)
            expect(!FileManager.default.fileExists(atPath: masterPath), "the master key must go with the last key")

            // A damaged master key blocks saving, and removing clears the way.
            try await store.save(text, provider: .aliyunBeijing)
            let damaged = open(masterPath, O_WRONLY | O_TRUNC)
            expect(damaged >= 0, "the damaged master key fixture must be opened for writing")
            if damaged >= 0 {
                let bytes: [UInt8] = [1, 2, 3, 4, 5]
                expect(write(damaged, bytes, bytes.count) == bytes.count, "the damaged master key fixture must be written")
                close(damaged)
            }
            var readable = true
            do { _ = try await store.isSaved(provider: .aliyunBeijing) } catch { readable = false }
            expect(!readable, "a damaged master key must make the saved key unreadable")
            do {
                try await store.save(text, provider: .aliyunBeijing)
                expect(false, "saving over a damaged master key must fail")
            } catch {
                // expected
            }
            try await store.remove(provider: .aliyunBeijing)
            try await store.save(text, provider: .aliyunBeijing)
            expect(try await store.readForPipe(provider: .aliyunBeijing) == fakeKey, "after removing the damaged store a new key must save and read back")

            // An older key of another provider must not keep a damaged store stuck: with the master key gone
            // it is undecryptable anyway, so removing clears it too.
            try await store.save(otherText, provider: .groq)
            let stillDamaged = open(masterPath, O_WRONLY | O_TRUNC)
            expect(stillDamaged >= 0, "the second damaged master key fixture must be opened for writing")
            if stillDamaged >= 0 {
                let bytes: [UInt8] = [9, 9, 9]
                _ = write(stillDamaged, bytes, bytes.count)
                close(stillDamaged)
            }
            try await store.remove(provider: .aliyunBeijing)
            var groqGone = false
            do { groqGone = try await store.isSaved(provider: .groq) == false } catch { groqGone = false }
            expect(groqGone, "a damaged master key must take every stored key with it when removing")
            expect(!FileManager.default.fileExists(atPath: masterPath), "a damaged master key file must be removed")
            try await store.save(text, provider: .aliyunBeijing)
            expect(try await store.readForPipe(provider: .aliyunBeijing) == fakeKey, "saving must work again once the damaged store is cleared")

            // A missing master key with a key file left behind is just as stuck, and clears the same way.
            expect(unlink(masterPath) == 0, "the master key fixture must be removable")
            var missingReadable = true
            do { _ = try await store.isSaved(provider: .aliyunBeijing) } catch { missingReadable = false }
            expect(!missingReadable, "a key file without its master key must read as unreadable")
            try await store.remove(provider: .aliyunBeijing)
            try await store.save(text, provider: .aliyunBeijing)
            expect(try await store.readForPipe(provider: .aliyunBeijing) == fakeKey, "saving must work after clearing a key file that lost its master key")
        } catch {
            expect(false, "credential removal checks threw \(error)")
        }
        return failures
    }
}
