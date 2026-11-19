// I03W — relative bundle factory for GroqSpeechBackend.
// No keys are read and no mic/network is launched during factory creation.

import Foundation

@MainActor
internal enum GroqBackendFactory {

    internal enum FactoryError: Error {
        case unavailable
    }

    internal static func make(consentGranted: Bool, provider: OnlineAPIProvider = .groq, credentialRevision: String? = nil,
        makeCapture: @escaping @MainActor () -> any LocalSpeechCapture = { SharedCaptureHub.liveSource() }) -> GroqSpeechBackend {
        let credentials = CloudCredentialStore()
        return GroqSpeechBackend(
            consentGranted: consentGranted,
            provider: provider,
            makeTransport: { snapshot in
                guard let backend = IntegratedRuntimePaths.backendResources,
                      let assets = IntegratedRuntimePaths.assetRoot else {
                    throw FactoryError.unavailable
                }
                let fm = FileManager.default
                let resRoot = Bundle.main.resourceURL?.resolvingSymlinksInPath().path
                let backPath = backend.resolvingSymlinksInPath().path
                let assetsPath = assets.resolvingSymlinksInPath().path
                guard let resRoot,
                      backPath.hasPrefix(resRoot + "/"),
                      assetsPath.hasPrefix(resRoot + "/") else {
                    throw FactoryError.unavailable
                }
                func regularNonSymlink(_ url: URL) throws {
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw FactoryError.unavailable }
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw FactoryError.unavailable
                    }
                }
                guard provider == .groq || provider == .openai || provider == .siliconflow else { throw FactoryError.unavailable }
                let launcher = backend.appendingPathComponent(provider == .groq ? "launch-cloud-worker.sh" : provider == .siliconflow ? "launch-siliconflow-worker.sh" : "launch-openai-worker.sh", isDirectory: false)
                let sandbox = backend.appendingPathComponent(provider == .groq ? "cloud-worker.sb" : provider == .siliconflow ? "siliconflow-worker.sb" : "openai-worker.sb", isDirectory: false)
                let worker = backend.appendingPathComponent(provider == .groq ? "cloud_groq_worker.py" : "cloud_openai_worker.py", isDirectory: false)
                try regularNonSymlink(launcher)
                try regularNonSymlink(sandbox)
                try regularNonSymlink(worker)
                let python = assets.appendingPathComponent(
                    ".cache/venvs/voicenative-beta/bin/python", isDirectory: false)
                guard fm.isExecutableFile(atPath: python.path) else {
                    throw FactoryError.unavailable
                }
                let pythonResolved = python.resolvingSymlinksInPath().path
                guard pythonResolved.hasPrefix(assetsPath + "/") else {
                    throw FactoryError.unavailable
                }
                let configuration = snapshot.onlineAPIConfiguration
                if let configuration {
                    guard configuration.provider == provider, configuration.routeID == snapshot.selection.routeID else { throw FactoryError.unavailable }
                    _ = try configuration.validatedEndpoint()
                }
                return try GroqTranscriptionClient(
                    command: ["/bin/bash", launcher.path],
                    sessionID: snapshot.sessionID,
                    routeID: snapshot.selection.routeID,
                    language: snapshot.selection.language,
                    timeout: 45, provider: provider, modelID: configuration?.modelID
                )
            },
            readCredential: {
                try await credentials.readForPipe(provider: provider == .groq ? .groq : provider == .siliconflow ? .siliconflow : .openai, expectedRevision: credentialRevision)
            }, makeCapture: makeCapture
        )
    }
}
