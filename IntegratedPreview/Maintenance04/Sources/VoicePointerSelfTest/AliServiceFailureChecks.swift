import Foundation
import VoicePointerCore

/// Non-XCTest checks for the finite AliServiceFailure vocabulary.
enum AliServiceFailureChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let exact: [String: AliServiceFailure.Code] = [
            "InvalidApiKey": .authFailed,
            "invalid_api_key": .authFailed,
            "Arrearage": .balanceDue,
            "AllocationQuota.FreeTierOnly": .freeQuotaExhausted,
            "AccessDenied.Unpurchased": .accessDenied,
            "Model.AccessDenied": .accessDenied,
            "Throttling.RateQuota": .rateLimited,
            "Throttling.BurstRate": .rateLimited,
            "Throttling.AllocationQuota": .rateLimited,
            "Throttling.Concurrency": .rateLimited,
            "ModelNotFound": .modelUnavailable,
            "model_not_found": .modelUnavailable,
            "ModelUnavailable": .modelUnavailable,
            "CLIENT_ERROR": .invalidRequest,
        ]
        for (raw, code) in exact {
            expect(AliServiceFailure.fromServiceCode(raw).code == code, "serviceCode \(raw)")
        }

        let secret = "arbitrarylongsecretstring-9817ALIINVALIDCODE"
        let unknown = AliServiceFailure.fromServiceCode(secret)
        expect(unknown.code == .streamFailed, "unknown -> streamFailed")
        expect(AliServiceFailure.fromServiceCode(nil).code == .streamFailed, "nil -> streamFailed")
        expect(!String(describing: unknown).contains(secret), "secret absent")

        let http: [Int: AliServiceFailure.Code] = [
            401: .authFailed, 403: .accessDenied, 408: .timeout, 429: .rateLimited,
            500: .serviceUnavailable, 503: .serviceUnavailable, 599: .serviceUnavailable,
            400: .streamFailed, 404: .streamFailed, 200: .streamFailed,
        ]
        for (status, code) in http {
            expect(AliServiceFailure.fromHTTPStatus(status).code == code, "http \(status)")
        }

        expect(AliServiceFailure.transport(URLError(.timedOut)).code == .timeout, "url timeout")
        expect(AliServiceFailure.transport(URLError(.cannotFindHost)).code == .networkFailed, "url dns")
        expect(AliServiceFailure.transport(URLError(.cannotConnectToHost)).code == .networkFailed, "url connect")
        expect(AliServiceFailure.transport(NSError(domain: "x", code: 1)).code == .streamFailed, "other error")

        let existing = AliServiceFailure(.authFailed)
        expect(AliServiceFailure.transport(existing).code == .authFailed, "typed retained")
        expect(AliServiceFailure.transport(existing, httpStatus: 500).code == .authFailed, "typed retained over status")
        expect(AliServiceFailure.transport(NSError(domain: "x", code: 2), httpStatus: 500).code == .serviceUnavailable, "status override present")

        expect(AliServiceFailure.transport(URLError(.timedOut), httpStatus: 101).code == .timeout, "successful upgrade must not mask timeout")

        // Inject typed service failures through the same contract used by the production event log and HUD.
        let diagnostics: [AliServiceFailure.Code: SpeechFailureDiagnostics.AliCode] = [
            .authFailed: .authFailed, .accessDenied: .accessDenied,
            .freeQuotaExhausted: .freeQuotaExhausted, .balanceDue: .balanceDue,
            .rateLimited: .rateLimited, .modelUnavailable: .modelUnavailable,
            .serviceUnavailable: .serviceUnavailable, .networkFailed: .networkFailed,
            .timeout: .timeout, .invalidRequest: .invalidRequest, .streamFailed: .streamFailed,
        ]
        expect(Set(diagnostics.keys) == Set(AliServiceFailure.Code.allCases), "every typed service failure is covered")
        for (service, expected) in diagnostics {
            let error = AliServiceFailure(service)
            let diagnostic = SpeechFailureDiagnostics.aliDiagnostic(for: error)
            expect(diagnostic?.code == expected, "typed diagnostic \(service.rawValue)")
            expect(SpeechFailureDiagnostics.code(for: error) == expected.rawValue, "derived log code \(service.rawValue)")
            expect(SpeechFailureDiagnostics.safeCode(expected.rawValue) == expected.rawValue, "event code retained \(service.rawValue)")
            let shown = VoiceIssuePresentationPolicy.forBackendCode(expected.rawValue)
            expect(shown.message == diagnostic?.message, "production message \(service.rawValue)")
            expect(VoiceIssuePresentationPolicy.runtimeStatus(for: shown, isPresentationAllowed: true) == .failed(shown.message),
                   "production HUD message \(service.rawValue)")
        }

        let connection: [CloudConnectionCheck.Failure: SpeechFailureDiagnostics.AliCode] = [
            .noKey: .credentialMissing, .keyUnreadable: .credentialUnreadable,
            .rejectedKey: .authFailed, .noAccess: .accessDenied,
            .freeQuotaExhausted: .freeQuotaExhausted, .balanceDue: .balanceDue,
            .rateLimited: .rateLimited, .modelUnavailable: .modelUnavailable,
            .serviceUnavailable: .serviceUnavailable, .network: .networkFailed,
            .timeout: .timeout, .worker: .workerFailed, .taskStartFailed: .taskStartFailed,
            .notClosed: .cleanup, .unknown: .streamFailed,
        ]
        expect(Set(connection.keys) == Set(CloudConnectionCheck.Failure.allCases), "every F4 failure is covered")
        for (failure, expected) in connection {
            let diagnostic = SpeechFailureDiagnostics.aliDiagnostic(for: failure)
            expect(diagnostic.code == expected && failure.message == diagnostic.message, "F4 contract \(failure)")
            expect(!diagnostic.message.contains("Key 没问题"), "no unsupported authentication claim \(failure)")
        }

        for code in SpeechFailureDiagnostics.AliCode.allCases {
            expect(SpeechFailureDiagnostics.safeCode(code.rawValue) == code.rawValue, "finite Ali allowlist \(code.rawValue)")
            let diagnostic = SpeechFailureDiagnostics.AliDiagnostic(code: code)
            expect(!diagnostic.message.isEmpty && diagnostic.message.hasSuffix("。"), "actionable Ali message \(code.rawValue)")
            expect(diagnostic.message != "语音识别失败，请重试", "Ali message remains specific \(code.rawValue)")
            for near in [code.rawValue.lowercased(), code.rawValue + " ", code.rawValue + "_UNKNOWN"] {
                expect(SpeechFailureDiagnostics.safeCode(near) == "GROQ_TRANSCRIBE_FAILED", "exact Ali allowlist")
            }
        }

        let foreign = NSError(domain: "ALI_AUTH_FAILED", code: 401,
                              userInfo: [NSLocalizedDescriptionKey: secret])
        expect(SpeechFailureDiagnostics.aliDiagnostic(for: foreign) == nil, "foreign error has no inferred Ali cause")
        expect(SpeechFailureDiagnostics.code(for: foreign) == "GROQ_TRANSCRIBE_FAILED", "foreign error stays generic")
        expect(SpeechFailureDiagnostics.aliDiagnostic(for: URLError(.cannotConnectToHost)) == nil,
               "unscoped transport error has no inferred provider")
        expect(!SpeechFailureDiagnostics.message(for: secret).contains(secret), "message never echoes input")
        expect(SpeechFailureDiagnostics.code(for: unknown) == "ALI_STREAM_FAILED", "unknown service is an Ali failure without a guessed cause")
        expect(SpeechFailureDiagnostics.code(for: CredentialError.invalidKey) == "CREDENTIAL_INVALID", "existing generic credential mapping retained")
        expect(SpeechFailureDiagnostics.code(for: CancellationError()) == "GROQ_CANCELLED", "existing cancellation mapping retained")
        expect(SpeechFailureDiagnostics.aliDiagnostic(for: CredentialError.invalidKey)?.code == .credentialInvalid,
               "local invalid key format does not imply service rejection")
        expect(SpeechFailureDiagnostics.code(for: CloudConnectionCheck.HandshakeError.workerUnavailable) == "ALI_WORKER_FAILED", "worker startup evidence")
        expect(SpeechFailureDiagnostics.code(for: AliWireError.taskFailed) == "ALI_TASK_FAILED", "task failure without inferred cause")
        expect(SpeechFailureDiagnostics.code(for: AliEndpointError.invalid) == "ALI_ENDPOINT_INVALID", "endpoint validation evidence")

        for code in ["GROQ_HTTP_401", "GROQ_HTTP_403", "GROQ_HTTP_429", "GROQ_REQUEST_FAILED",
                     "LINE_WORKER_TIMEOUT", "HYBRID_FINAL_INCOMPLETE", "MICROPHONE_NO_SOUND", "MICROPHONE_NO_CALLBACKS"] {
            expect(SpeechFailureDiagnostics.safeCode(code) == code, "existing provider code retained \(code)")
        }
        expect(SpeechFailureDiagnostics.safeCode("http_401") == "GROQ_HTTP_401", "existing Groq worker mapping retained")
        expect(SpeechFailureDiagnostics.message(for: "GROQ_HTTP_401") == "API Key 无效，请重新配置", "existing Groq auth wording retained")
        expect(!SpeechFailureDiagnostics.AliDiagnostic(code: .freeQuotaExhausted).message.contains("已暂停"),
               "diagnosis does not assert an unconfirmed billing or pause state")
        return failures
    }
}
