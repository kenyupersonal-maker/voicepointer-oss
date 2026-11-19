import Foundation

/// Constructs the Ali realtime backend without ever touching the API key.
/// The key is only ever read (from the local encrypted credential store) inside
/// the backend's own readCredential closure, over an in-memory pipe; it is never
/// placed in arguments, environment, logs, or persisted files.
/// K06: a backend is only constructed for an admitted permit; the factory has no path without one.
@MainActor
internal enum AliBackendFactory {

    enum FactoryError: Error {
        case unavailable
    }

    /// The bundled worker's launcher script, after checking that the launcher, the sandbox profile and the worker
    /// binary are regular files that stay inside the app bundle's resources once symlinks are resolved, and that
    /// the worker is executable. Shared by the dictation backend and the settings' connection test, so both
    /// launch exactly the same worker the same way. No key material is involved.
    nonisolated static func workerLauncher() throws -> URL {
        // Resolve the bundled backend resources root physically
        // (no symlink traversal escapes the bundle).
        guard let resourceRoot = Bundle.main.resourceURL else {
            throw FactoryError.unavailable
        }
        let resRoot = resourceRoot.resolvingSymlinksInPath().path
        guard let backend = IntegratedRuntimePaths.backendResources else {
            throw FactoryError.unavailable
        }
        let backendResolved = backend.resolvingSymlinksInPath().path

        // The backend directory must live inside the app bundle's
        // resolved resource root.
        let resPrefix = resRoot.hasSuffix("/") ? resRoot : resRoot + "/"
        guard backendResolved.hasPrefix(resPrefix) else {
            throw FactoryError.unavailable
        }

        let backendPrefix = backendResolved.hasSuffix("/") ? backendResolved : backendResolved + "/"

        // Required files: launcher script, sandbox profile, worker binary.
        let launcher = URL(fileURLWithPath: backendPrefix + "launch-ali-worker.sh")
        let profile = URL(fileURLWithPath: backendPrefix + "ali-worker.sb")
        let worker = URL(fileURLWithPath: backendPrefix + "AliRealtimeWorker")

        var requiredFiles: [URL] = []
        for url in [launcher, profile, worker] {
            let resolved = url.resolvingSymlinksInPath()

            // Must be a regular file, not a symlink.
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard let values = values,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw FactoryError.unavailable
            }

            // Each resolved file must remain inside the resolved
            // backend directory (prefix check on the resolved path).
            guard resolved.path.hasPrefix(backendPrefix) else {
                throw FactoryError.unavailable
            }
            requiredFiles.append(resolved)
        }

        let resolvedWorker = requiredFiles[2]
        guard FileManager.default.isExecutableFile(atPath: resolvedWorker.path) else {
            throw FactoryError.unavailable
        }
        return launcher
    }

    /// `makeCapture` / `requestPermission` default to what the backend uses on its own (its own microphone
    /// pipeline, the real permission prompt). The hybrid mode passes the shared capture's view and the one
    /// memoized permission answer instead, so the cloud branch never opens a second microphone or a second prompt.
    static func make(
        consentGranted: Bool,
        endpoint: String,
        admission: CloudStreamAdmission,
        modelID: String = AliWireCodec.legacyModelID,
        credentialRevision: String? = nil,
        makeCapture: @escaping @MainActor () -> any LocalSpeechCapture = {
            LiveAudioPipeline(
                capacity: 32,
                appleEnabled: false,
                captureByteLimit: 256 * 1024 * 1024,
                captureDurationSeconds: 300,
                gracefulDurationLimit: true
            )
        },
        requestPermission: @escaping @MainActor () async -> Bool = {
            await LocalSpeechBackend.requestMicrophonePermission()
        }
    ) throws -> AliSpeechBackend {
        // Validate the endpoint before any backend state is created. Only the
        // (non-secret) endpoint string is carried forward; no key material is
        // read here.
        let validatedEndpoint = try AliEndpoint(endpoint)
        let credentials = CloudCredentialStore()

        return AliSpeechBackend(
            consentGranted: consentGranted,
            makeTransport: { snapshot in
                // Snapshot-level route validation (local vs. cloud route,
                // language, etc.) is performed inside the backend before this
                // closure is invoked; here we only assemble the transport.
                let launcher = try workerLauncher()

                // Ali requires no bundled Python or model assets; the worker is
                // a self-contained executable launched through its sandboxed
                // launcher. No developer paths are involved.
                return try AliTranscriptionClient(
                    sessionID: snapshot.sessionID,
                    endpoint: validatedEndpoint,
                    language: snapshot.selection.language,
                    worker: StreamingLineWorker(
                        command: ["/bin/bash", launcher.path]
                    ), modelID: modelID
                )
            },
            readCredential: {
                try await credentials.readForPipe(provider: .aliyunBeijing, expectedRevision: credentialRevision)
            },
            requestPermission: requestPermission,
            makeCapture: makeCapture,
            admission: admission
        )
    }

    /// The handshake behind the settings' "测试连接": the same sandboxed worker and the same start message as a
    /// dictation, but no audio and no transcript. It returns once the service has accepted the task and has then
    /// closed the worker again; it throws the client's own failure (an `AliServiceFailure` when the service or the
    /// network said no). The key arrives as an argument, never from here, and is only handed to the worker's pipe.
    nonisolated static func makeConnectionHandshake(
        endpoint: String,
        modelID: String = AliWireCodec.legacyModelID,
        observe: (@Sendable (CloudConnectionCheck.HandshakeObservation) -> Void)? = nil
    ) throws -> @Sendable (Data) async throws -> Void {
        let validatedEndpoint = try AliEndpoint(endpoint)
        return { credential in
            let launcher: URL
            do {
                launcher = try workerLauncher()
            } catch {
                throw CloudConnectionCheck.HandshakeError.workerUnavailable
            }
            let client = try AliTranscriptionClient(
                sessionID: UUID(),
                endpoint: validatedEndpoint,
                language: "auto",
                worker: StreamingLineWorker(command: ["/bin/bash", launcher.path]),
                modelID: modelID,
                checkOnly: true
            )
            try await withTaskCancellationHandler {
                // A failed prepare has already shut the worker down.
                do {
                    try await client.prepare(credential: credential)
                } catch {
                    if let source = (error as? AliServiceFailure)?.evidence?.source {
                        observe?(.serviceFailure(source))
                    }
                    observe?(.workerQuiescent(await client.isQuiescent()))
                    throw error
                }
                observe?(.taskStarted)
                do { try await client.finishConnectionCheck() }
                catch { await client.cancel(); throw error }
                observe?(.cancellationRequested)
                await client.cancel()
                let quiescent = await client.isQuiescent()
                observe?(.workerQuiescent(quiescent))
                guard quiescent else {
                    throw CloudConnectionCheck.HandshakeError.notClosed
                }
            } onCancel: {
                observe?(.cancellationRequested)
                Task {
                    await client.cancel()
                    observe?(.workerQuiescent(await client.isQuiescent()))
                }
            }
        }
    }
}
