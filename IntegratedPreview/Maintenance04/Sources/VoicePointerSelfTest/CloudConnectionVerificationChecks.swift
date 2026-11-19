import Foundation
import VoicePointerCore

/// Synthetic closures only: no credential storage, worker, audio or network.
@MainActor
enum CloudConnectionVerificationChecks {
    @MainActor private final class Trace {
        var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
    private actor DelayedHandshake {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Void, Never>?
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func run() async {
            await withCheckedContinuation {
                completion = $0; started = true; waiter?.resume(); waiter = nil
            }
        }
        func complete() { completion?.resume(); completion = nil }
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        let fakeKey = Data("sk-synthetic-f4-placeholder".utf8)
        let trace = Trace()
        let connected = await CloudConnectionVerificationFlow.run(readKey: {
            await trace.record("read"); return fakeKey
        }, handshake: { key in
            if key != fakeKey { throw CredentialError.invalidKey }
            await trace.record("handshake")
        }, isCurrent: { true })
        expect(connected == .authenticated && trace.events == ["read", "handshake"],
               "explicit connection uses only the injected credential and handshake")

        for failure in CloudConnectionCheck.Failure.allCases {
            let diagnostic = SpeechFailureDiagnostics.aliDiagnostic(for: failure)
            expect(CloudConnectionVerificationFlow.failureMessage(failure) == diagnostic.message
                && diagnostic.code.rawValue.hasPrefix("ALI_") && !diagnostic.message.contains("sk-"),
                "connection reuses F1's finite diagnostic without credential content: \(failure)")
        }
        expect(CloudConnectionVerificationFlow.failureMessage(.rejectedKey).contains("设置 → 语音输入 → 在线 API")
            && CloudConnectionVerificationFlow.failureMessage(.network).contains("代理")
            && CloudConnectionVerificationFlow.failureMessage(.freeQuotaExhausted).contains("百炼控制台"),
            "Key/network/quota diagnostics contain actionable next steps")

        let serviceFailures: [(AliServiceFailure.Code, CloudConnectionCheck.Failure)] = [
            (.authFailed, .rejectedKey), (.accessDenied, .noAccess),
            (.freeQuotaExhausted, .freeQuotaExhausted), (.balanceDue, .balanceDue),
            (.rateLimited, .rateLimited), (.modelUnavailable, .modelUnavailable),
            (.serviceUnavailable, .serviceUnavailable), (.networkFailed, .network),
            (.timeout, .timeout), (.invalidRequest, .unknown), (.streamFailed, .unknown),
        ]
        expect(Set(serviceFailures.map(\.0)) == Set(AliServiceFailure.Code.allCases),
               "connection fixtures cover every Aliyun service failure")
        for (code, expected) in serviceFailures {
            let result = await CloudConnectionVerificationFlow.run(readKey: { fakeKey },
                handshake: { _ in throw AliServiceFailure(code) }, isCurrent: { true })
            expect(result == .connectionFailed(expected), "connection preserves typed Aliyun failure \(code)")
        }
        for error in [CredentialError.missing, .corrupt, .storage, .invalidKey] {
            trace.events = []
            let result = await CloudConnectionVerificationFlow.run(readKey: { throw error },
                handshake: { _ in await trace.record("handshake") }, isCurrent: { true })
            expect(result == .connectionFailed(error == .missing ? .noKey : .keyUnreadable)
                && trace.events.isEmpty, "unreadable/missing credential never reaches the handshake")
        }
        let transportFailures: [(any Error, CloudConnectionCheck.Failure)] = [
            (URLError(.notConnectedToInternet), .network), (URLError(.timedOut), .timeout),
            (CloudConnectionCheck.HandshakeError.workerUnavailable, .worker),
            (CloudConnectionCheck.HandshakeError.notClosed, .notClosed),
        ]
        for (error, expected) in transportFailures {
            let result = await CloudConnectionVerificationFlow.run(readKey: { fakeKey },
                handshake: { _ in throw error }, isCurrent: { true })
            expect(result == .connectionFailed(expected), "connection preserves transport/worker failure \(expected)")
        }

        for purpose in [CloudEntryPurpose.route, .enhanceLocal] {
            for failed in [false, true] {
                trace.events = []
                let epoch = UUID()
                let actions = CloudSetupFlow.Actions(save: { _ in trace.record("save"); return epoch },
                    verify: { _ in
                        await CloudConnectionVerificationFlow.run(readKey: {
                            await trace.record("read"); return fakeKey
                        }, handshake: { _ in
                            await trace.record("handshake")
                            if failed { throw AliServiceFailure(.accessDenied) }
                        }, isCurrent: { true })
                    }, confirm: { _ in trace.record("confirm"); return true },
                    allowUpload: { _ in trace.record("consent") },
                    enable: { _, _ in trace.record("enable"); return true },
                    refresh: { trace.record("refresh") }, credentialIsCurrent: { $0 == epoch },
                    beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                    commitAuthorization: { _ in true }, rollbackAuthorization: { _ in trace.record("rollback") })
                let result = await CloudSetupFlow.run(draft: "sk-synthetic-f4-placeholder", quotaAcknowledged: true,
                    purpose: purpose, actions: actions, isVisible: { true })
                expect(result == (failed ? .connectionFailed(.noAccess) : .enabled(authorizedEpoch: epoch))
                    && trace.events == (failed ? ["save", "read", "handshake", "refresh"]
                        : ["save", "read", "handshake", "confirm", "consent", "enable", "refresh"]),
                    "setup preserves save/verify/confirm/consent/enable order for \(purpose), failure=\(failed)")

                trace.events = []
                let renewed = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
                    quotaAcknowledged: true, actions: actions, isVisible: { true })
                expect(renewed == (failed ? .connectionFailed(.noAccess) : .renewed(authorizedEpoch: epoch))
                    && trace.events == (failed ? ["read", "handshake", "refresh"]
                        : ["read", "handshake", "confirm", "refresh"]),
                    "renewal verifies saved key and never grants consent or enables \(purpose)")
            }
        }

        // Replacing a rejected saved Key is a confirmation-only operation.
        // It preserves the setup order while never requesting consent/enable.
        for scenario in 0..<4 {
            trace.events = []
            let oldEpoch = UUID(), newEpoch = UUID()
            var currentEpoch = oldEpoch
            let actions = CloudSetupFlow.Actions(save: { _ in
                trace.record("save"); currentEpoch = newEpoch; return newEpoch
            }, verify: { epoch in
                trace.record("verify")
                expect(epoch == newEpoch, "replacement verifies its own saved epoch")
                if scenario == 3 { currentEpoch = UUID() }
                return scenario == 1 ? .connectionFailed(.rejectedKey) : .authenticated
            }, confirm: { epoch in
                trace.record("confirm")
                expect(epoch == newEpoch, "replacement confirms its own verified epoch")
                return true
            }, allowUpload: { _ in trace.record("consent") },
                enable: { _, _ in trace.record("enable"); return true },
                refresh: { trace.record("refresh") }, credentialIsCurrent: { $0 == currentEpoch },
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in trace.record("rollback") })
            let result = await CloudSetupFlow.replaceSavedCredential(
                draft: scenario == 2 ? "invalid-synthetic-format" : "sk-synthetic-replacement",
                quotaAcknowledged: true, actions: actions, isVisible: { true })
            switch scenario {
            case 0: expect(result == .renewed(authorizedEpoch: newEpoch)
                && trace.events == ["save", "verify", "confirm", "refresh"], "replacement remains confirmation-only")
            case 1: expect(result == .connectionFailed(.rejectedKey)
                && trace.events == ["save", "verify", "refresh"], "failed replacement never confirms or enables")
            case 2: expect(result == .invalidFormat && trace.events.isEmpty && currentEpoch == oldEpoch,
                "invalid replacement preserves the existing credential")
            default: expect(result == .cancelled && trace.events == ["save", "verify"],
                "replaced epoch cannot confirm a late successful result")
            }
        }

        trace.events = []
        let notCurrent = await CloudConnectionVerificationFlow.run(readKey: {
            await trace.record("read"); return fakeKey
        }, handshake: { _ in await trace.record("handshake") }, isCurrent: { false })
        expect(notCurrent == .notNetworkVerified && trace.events.isEmpty,
               "hidden/stale connection never reads a credential or starts a handshake")

        trace.events = []
        let cancelledBeforeStart = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await CloudConnectionCheck.run(readKey: {
                await trace.record("read"); return fakeKey
            }, handshake: { _ in await trace.record("handshake") })
        }.value
        expect(cancelledBeforeStart == .failed(.unknown) && trace.events.isEmpty,
               "already-cancelled connection never reads or starts work")

        let delayedRead = DelayedHandshake()
        var keyIsCurrent = true
        trace.events = []
        let replacedDuringRead = Task { @MainActor in
            await CloudConnectionVerificationFlow.run(readKey: {
                await delayedRead.run(); return fakeKey
            }, handshake: { _ in await trace.record("handshake") }, isCurrent: { keyIsCurrent })
        }
        await delayedRead.waitUntilStarted(); keyIsCurrent = false; await delayedRead.complete()
        expect(await replacedDuringRead.value == .notNetworkVerified && trace.events.isEmpty,
               "credential replacement during a suspended read prevents handshake")

        // The fake ignores cancellation and returns late. Cancellation must
        // release the caller and tell the underlying handshake to stop first.
        let delayed = DelayedHandshake(), stopped = CancellationFlag()
        let cancelledTask = Task { @MainActor in
            await CloudConnectionVerificationFlow.run(readKey: { fakeKey }, handshake: { _ in
                await withTaskCancellationHandler(operation: { await delayed.run() }, onCancel: { stopped.set() })
            }, isCurrent: { true })
        }
        await delayed.waitUntilStarted()
        let cancellationStart = Date()
        cancelledTask.cancel()
        let cancelled = await cancelledTask.value
        expect(cancelled == .notNetworkVerified && stopped.isSet && Date().timeIntervalSince(cancellationStart) < 1,
               "cancellation stops handshake and releases caller without waiting for a late callback")
        await delayed.complete()

        let stale = DelayedHandshake()
        var current = true
        let staleTask = Task { @MainActor in
            await CloudConnectionVerificationFlow.run(readKey: { fakeKey },
                handshake: { _ in await stale.run() }, isCurrent: { current })
        }
        await stale.waitUntilStarted(); current = false; await stale.complete()
        expect(await staleTask.value == .notNetworkVerified, "late connection success cannot confirm a changed epoch")

        let timedOut = CancellationFlag()
        let timeout = await CloudConnectionVerificationFlow.run(timeout: 0.05, readKey: { fakeKey }, handshake: { _ in
            try await withTaskCancellationHandler(operation: { try await Task.sleep(for: .seconds(30)) },
                onCancel: { timedOut.set() })
        }, isCurrent: { true })
        expect(timeout == .connectionFailed(.timeout) && timedOut.isSet,
               "connection timeout is typed and cancels its handshake")
        return failures
    }
}
