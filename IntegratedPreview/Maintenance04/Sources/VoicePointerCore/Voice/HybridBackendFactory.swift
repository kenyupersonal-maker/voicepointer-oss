import Foundation

/// The Aliyun backend's uplink, for the hybrid backend's backlog rule: 16 kHz mono 16-bit PCM is 32 bytes per ms.
extension AliSpeechBackend: CloudUplinkReporting {
    var uplinkSentMilliseconds: Int64 { Int64(sentBytes / 32) }
}

/// Builds the hybrid backend ("用于增强本地识别") from the real local and Aliyun backends. It never reads the key
/// and opens nothing: the capture, the permission prompt and the cloud stream all start later, from the hybrid
/// backend's `start`, local branch first.
enum HybridBackendFactory {
    enum FactoryError: Error {
        case consentMissing
        case routeNotEnhanceable
    }

    /// Builds the local+cloud backend for one dictation. Throws when the cloud endpoint is not valid or the
    /// route cannot be enhanced; the coordinator then uses the plain local backend.
    @MainActor static func make(
        pool: LocalWorkerPool,
        route: HybridSpeechRoute,
        consentGranted: Bool,
        endpoint: String,
        admission: CloudStreamAdmission?,
        modelID: String = AliWireCodec.legacyModelID,
        credentialRevision: String? = nil,
        learningReceiver: (@MainActor @Sendable (EnhancementComparison) -> Void)? = nil,
        teacherFinalReceiver: (@MainActor @Sendable (UUID, String) -> Void)? = nil,
        configuration: OnlineAPIConfiguration? = nil
    ) throws -> HybridSpeechBackend {
        guard consentGranted else { throw FactoryError.consentMissing }
        let provider = configuration?.provider ?? .aliyunBailian
        if !provider.isAliyun {
            guard let configuration else { throw FactoryError.routeNotEnhanceable }
            _ = try configuration.validatedEndpoint()
            return HybridSpeechBackend(route: route,
                makeSource: { SharedCaptureHub.liveSource() },
                requestPermission: { await LocalSpeechBackend.requestMicrophonePermission() },
                branches: .init(makeLocal: { capture, permission in
                    LocalSpeechBackend(pool: pool, requestPermission: permission, makeCapture: capture)
                }, makeCloud: { capture, _ in
                    GroqBackendFactory.make(consentGranted: consentGranted, provider: provider,
                        credentialRevision: configuration.credentialRevision, makeCapture: capture)
                }), learningReceiver: learningReceiver,
                teacherFinalReceiver: teacherFinalReceiver, configuration: configuration)
        }
        guard let admission else { throw FactoryError.consentMissing }
        // The Aliyun backend refuses any other language before it opens a stream: better the plain local
        // backend than a cloud branch that can only fail.
        guard CloudEntry.supportedLanguages.contains(route.language) else { throw FactoryError.routeNotEnhanceable }
        // Validated here so an invalid endpoint falls back to the local route; the Aliyun factory checks it again.
        _ = try AliEndpoint(endpoint)
        return HybridSpeechBackend(
            route: route,
            makeSource: { SharedCaptureHub.liveSource() },
            requestPermission: { await LocalSpeechBackend.requestMicrophonePermission() },
            branches: HybridSpeechBackend.Branches(
                makeLocal: { capture, permission in
                    LocalSpeechBackend(pool: pool, requestPermission: permission, makeCapture: capture)
                },
                makeCloud: { capture, permission in
                    try AliBackendFactory.make(
                        consentGranted: consentGranted,
                        endpoint: endpoint,
                        admission: admission,
                        modelID: modelID,
                        credentialRevision: credentialRevision,
                        makeCapture: capture,
                        requestPermission: permission
                    )
                }
            ),
            learningReceiver: learningReceiver,
            teacherFinalReceiver: teacherFinalReceiver
        )
    }
}
