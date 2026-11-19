//
//  Safe, finite error-code propagation for speech backend failures.
//  Never surfaces raw error text, localizedDescription, or unallowlisted codes.
//

import Foundation

public enum SpeechFailureDiagnostics {

    /// Stable Aliyun diagnostic contract shared by dictation and the connection-test UI.
    /// These codes describe the evidence available; they do not change billing or pause a route.
    public enum AliCode: String, CaseIterable, Sendable {
        case authFailed = "ALI_AUTH_FAILED"
        case accessDenied = "ALI_ACCESS_DENIED"
        case freeQuotaExhausted = "ALI_FREE_QUOTA_EXHAUSTED"
        case balanceDue = "ALI_BALANCE_DUE"
        case rateLimited = "ALI_RATE_LIMITED"
        case modelUnavailable = "ALI_MODEL_UNAVAILABLE"
        case serviceUnavailable = "ALI_SERVICE_UNAVAILABLE"
        case networkFailed = "ALI_NETWORK_FAILED"
        case timeout = "ALI_TIMEOUT"
        case invalidRequest = "ALI_INVALID_REQUEST"
        case streamFailed = "ALI_STREAM_FAILED"
        case credentialMissing = "ALI_CREDENTIAL_MISSING"
        case credentialUnreadable = "ALI_CREDENTIAL_UNREADABLE"
        case credentialInvalid = "ALI_CREDENTIAL_INVALID"
        case workerFailed = "ALI_WORKER_FAILED"
        case startFailed = "ALI_START_FAILED"
        case taskStartFailed = "ALI_TASK_START_FAILED"
        case microphonePermissionDenied = "ALI_MIC_PERMISSION_DENIED"
        case backendState = "ALI_BACKEND_STATE"
        case clientState = "ALI_CLIENT_STATE"
        case clientFailed = "ALI_CLIENT_FAILED"
        case protocolInvalid = "ALI_PROTOCOL_INVALID"
        case protocolOversize = "ALI_PROTOCOL_OVERSIZE"
        case taskFailed = "ALI_TASK_FAILED"
        case endpointInvalid = "ALI_ENDPOINT_INVALID"
        case cleanup = "ALI_CLEANUP"
        case cloudRevoked = "ALI_CLOUD_REVOKED"
    }

    public struct AliDiagnostic: Sendable, Equatable {
        public let code: AliCode
        public var message: String { SpeechFailureDiagnostics.message(for: code.rawValue) }

        public init(code: AliCode) { self.code = code }
    }

    /// Call on the Aliyun path. Foreign errors return nil, never a guessed cause.
    /// Local credential-format errors are distinct from a service rejection of the key.
    public static func aliDiagnostic(for error: any Error) -> AliDiagnostic? {
        let code: AliCode
        switch error {
        case let failure as AliServiceFailure:
            code = AliCode(rawValue: failure.code.rawValue) ?? .streamFailed
        case let credential as CredentialError:
            switch credential {
            case .missing: code = .credentialMissing
            case .corrupt, .storage: code = .credentialUnreadable
            case .invalidKey: code = .credentialInvalid
            }
        case let backend as AliBackendError:
            switch backend {
            case .invalid: code = .backendState
            case .permission: code = .microphonePermissionDenied
            case .startFailed: code = .startFailed
            }
        case let client as AliClientError:
            switch client {
            case .state: code = .clientState
            case .failed: code = .clientFailed
            case .cleanup: code = .cleanup
            case .taskStartFailed: code = .taskStartFailed
            }
        case let worker as StreamingWorkerError:
            switch worker {
            case .launch: code = .workerFailed
            case .cleanup: code = .cleanup
            case .state: code = .clientState
            case .invalid: code = .protocolInvalid
            }
        case is AliBackendFactory.FactoryError:
            code = .workerFailed
        case let handshake as CloudConnectionCheck.HandshakeError:
            switch handshake {
            case .workerUnavailable: code = .workerFailed
            case .notClosed: code = .cleanup
            }
        case let wire as AliWireError:
            switch wire {
            case .invalid: code = .protocolInvalid
            case .taskFailed: code = .taskFailed
            }
        case let ipc as AliIPCError:
            switch ipc {
            case .invalid: code = .protocolInvalid
            case .oversize: code = .protocolOversize
            }
        case is AliEndpointError:
            code = .endpointInvalid
        default:
            return nil
        }
        return AliDiagnostic(code: code)
    }

    /// F4 can present an already-classified handshake outcome without string matching or IO.
    public static func aliDiagnostic(for failure: CloudConnectionCheck.Failure) -> AliDiagnostic {
        let code: AliCode
        switch failure {
        case .noKey: code = .credentialMissing
        case .keyUnreadable: code = .credentialUnreadable
        case .rejectedKey: code = .authFailed
        case .noAccess: code = .accessDenied
        case .freeQuotaExhausted: code = .freeQuotaExhausted
        case .balanceDue: code = .balanceDue
        case .rateLimited: code = .rateLimited
        case .modelUnavailable: code = .modelUnavailable
        case .serviceUnavailable: code = .serviceUnavailable
        case .network: code = .networkFailed
        case .timeout: code = .timeout
        case .worker: code = .workerFailed
        case .taskStartFailed: code = .taskStartFailed
        case .notClosed: code = .cleanup
        case .unknown: code = .streamFailed
        }
        return AliDiagnostic(code: code)
    }

    // MARK: - Safe code normalization

    /// Normalizes an already-derived code string against the finite allowlist.
    /// Any unknown or arbitrary string collapses to the generic failure code.
    public static func safeCode(_ code: String) -> String {
        if openAICodes.contains(code) || isIntlCode(code) { return code }
        if let mapped = workerCodeMappings[code] { return mapped }
        if wireCodes.contains(code)
            || workerCodeMappings.values.contains(code)
            || workerCodes.contains(code)
            || clientCodes.contains(code)
            || credentialCodes.contains(code)
            || lifecycleCodes.contains(code)
            || hybridCodes.contains(code)
            || microphoneCodes.contains(code)
            || localCodes.contains(code)
            || AliCode(rawValue: code) != nil {
            return code
        }
        return "GROQ_TRANSCRIBE_FAILED"
    }

    // MARK: - Safe code derivation

    public static func code(for error: any Error) -> String {
        if error is CancellationError { return "GROQ_CANCELLED" }
        if let capture = error as? TrialCoreError, microphoneCodes.contains(capture.description) {
            return capture.description
        }

        if let credential = error as? CredentialError {
            switch credential {
            case .missing: return "CREDENTIAL_MISSING"
            case .corrupt: return "CREDENTIAL_CORRUPT"
            case .storage: return "CREDENTIAL_STORAGE"
            case .invalidKey: return "CREDENTIAL_INVALID"
            }
        }

        if let wire = error as? GroqWireError {
            if let mapped = workerCodeMappings[wire.code] { return mapped }
            return safeCode(wire.code)
        }

        if let worker = error as? LineWorkerError {
            return safeCode(worker.code)
        }

        if let client = error as? GroqClientError {
            return safeCode(client.code)
        }

        if let ali = aliDiagnostic(for: error) { return ali.code.rawValue }

        // GroqBackendError.invalid and foreign/unknown errors stay generic —
        // never mislabeled, never carrying arbitrary payload.
        return "GROQ_TRANSCRIBE_FAILED"
    }
    public static func localCode(_ raw: String, fallback: String = "LOCAL_CAPTURE_FAILED") -> String {
        microphoneCodes.contains(raw) || localCodes.contains(raw) ? raw : fallback
    }
    public static func localCode(for error: any Error, fallback: String = "LOCAL_START_FAILED") -> String {
        if let capture = error as? TrialCoreError { return localCode(capture.description, fallback: fallback) }
        if let worker = error as? BetaWorkerTransportError { return localCode(worker.description, fallback: fallback) }
        return fallback
    }

    // MARK: - Chinese UI messages

    public static func message(for code: String) -> String {
        if openAICodes.contains(code) { return OnlineAPIStrings.hud(provider: .openai, code: code) }
        if isIntlCode(code) { return OnlineAPIStrings.hud(provider: .aliyunIntl, code: code) }
        if let ali = AliCode(rawValue: code) { return aliMessage(for: ali) + "。" }
        switch code {
        case "AUDIO_ROUTE_CHANGED":
            return "麦克风切换了，请再试一次"
        case "AUDIO_ROUTE_REOPEN_FAILED":
            return "麦克风重连失败，请再试一次"
        case "INPUT_DEVICE_SELECTION_FAILED", "INPUT_DEVICE_UNAVAILABLE", "INPUT_DEVICE_FORMAT_UNAVAILABLE":
            return "麦克风打不开：到 系统设置 → 声音 → 输入，选 MacBook 麦克风"
        case "LOCAL_START_FAILED", "LOCAL_CAPTURE_FAILED", "LOCAL_INFERENCE_FAILED":
            return "本地识别失败，请再试一次"
        case "GROQ_HTTP_401", "GROQ_CREDENTIAL_INVALID", "CREDENTIAL_INVALID":
            return "API Key 无效，请重新配置"
        case "GROQ_HTTP_403":
            return "服务未授权，请检查账号权限"
        case "GROQ_HTTP_413":
            return "录音数据过大，请缩短录音后重试"
        case "GROQ_HTTP_429":
            return "请求过于频繁，请稍后重试"
        case "GROQ_HTTP_5XX":
            return "识别服务暂时不可用，请稍后重试"
        case "CREDENTIAL_MISSING":
            return "请在设置中配置 API Key"
        case "CREDENTIAL_CORRUPT":
            return "API Key 需要重新配置"
        case "CREDENTIAL_STORAGE":
            return "API Key 需要重新配置"
        case "GROQ_REQUEST_FAILED":
            return "网络连接失败"
        case "LINE_WORKER_TIMEOUT":
            return "网络连接失败"
        case "LINE_WORKER_LAUNCH", "LINE_WORKER_IO", "LINE_WORKER_CLOSED",
             "LINE_WORKER_BUSY", "LINE_WORKER_INVALID", "LINE_WORKER_OVERSIZE":
            return "本地识别进程异常，请重试"
        case "GROQ_CLEANUP":
            return "上一轮还在结束，请稍后再试"
        case "GROQ_CANCELLED":
            return "已取消语音识别"
        case "GROQ_TRANSCRIBE_FAILED":
            return "语音识别失败，请重试"
        default:
            return "语音识别失败，请重试"
        }
    }

    private static func aliMessage(for code: AliCode) -> String {
        switch code {
        case .authFailed:
            return "阿里云不认这个 Key，请到「设置 → 语音输入 → 在线 API」重新配置"
        case .credentialMissing:
            return "请到「设置 → 语音输入 → 在线 API」填写阿里云 API Key"
        case .credentialUnreadable:
            return "本机保存的阿里云 Key 无法读取，请到「设置 → 语音输入 → 在线 API」重新配置"
        case .credentialInvalid:
            return "阿里云 Key 格式不正确，请到「设置 → 语音输入 → 在线 API」重新填写完整 Key"
        case .accessDenied:
            return "阿里云未授权这次识别请求，请到百炼控制台检查账号和模型权限"
        case .freeQuotaExhausted:
            return "阿里云报告免费额度已用完，请检查百炼控制台的免费额度或切换识别方式"
        case .balanceDue:
            return "阿里云报告账号欠费或余额不足，请检查百炼控制台的账号状态或切换识别方式"
        case .rateLimited:
            return "阿里云请求受限，请稍后重试或切换识别方式"
        case .modelUnavailable:
            return "阿里云识别模型不可用，请检查百炼控制台的模型状态或切换识别方式"
        case .serviceUnavailable:
            return "阿里云服务暂时不可用，请稍后重试或切换识别方式"
        case .networkFailed:
            return "连不上阿里云，请检查网络或代理后重试"
        case .timeout:
            return "连接或等待阿里云响应超时，请检查网络或代理后重试"
        case .invalidRequest:
            return "阿里云未接受这次识别请求，请重试或检查在线 API 设置"
        case .workerFailed:
            return "阿里云识别组件不可用，请重启应用；仍失败请重新安装"
        case .startFailed:
            return "阿里云语音输入启动失败，请重启应用后重试"
        case .taskStartFailed:
            return "阿里云识别任务未能启动，请重启应用后重试或切换识别方式"
        case .microphonePermissionDenied:
            return "阿里云语音输入需要麦克风权限，请到系统设置中允许 VoicePointer 使用麦克风"
        case .backendState:
            return "阿里云语音输入当前无法开始，请检查在线 API 设置后重试"
        case .clientState:
            return "阿里云识别连接状态异常，请重启应用后重试"
        case .clientFailed:
            return "阿里云识别连接未能完成，请稍后重试；仍失败请重启应用"
        case .protocolInvalid, .protocolOversize:
            return "阿里云识别组件处理数据失败，请重启应用后重试"
        case .taskFailed:
            return "阿里云识别任务失败，请稍后重试或切换识别方式"
        case .endpointInvalid:
            return "阿里云连接地址不正确，请到「设置 → 语音输入 → 在线 API」检查设置"
        case .cleanup:
            return "阿里云上一轮连接还未确认关闭，请稍后重试；仍失败请重启应用"
        case .cloudRevoked:
            return "阿里云语音输入授权已撤回，请检查在线 API 设置或切换识别方式"
        case .streamFailed:
            return "阿里云识别未能完成，原因未确认，请稍后重试或切换识别方式"
        }
    }

    // MARK: - Finite allowlists

    private static let wireCodes: Set<String> = [
        "GROQ_WIRE_INVALID", "GROQ_WIRE_OVERSIZE", "GROQ_CREDENTIAL_INVALID", "GROQ_WORKER_FAILED",
    ]
    private static let openAICodes: Set<String> = ["OPENAI_HTTP_401", "OPENAI_HTTP_403", "OPENAI_HTTP_413", "OPENAI_HTTP_429", "OPENAI_HTTP_5XX",
        "OPENAI_INSUFFICIENT_QUOTA", "OPENAI_REQUEST_FAILED", "OPENAI_CREDENTIAL_INVALID", "OPENAI_CREDENTIAL_MISSING", "OPENAI_CREDENTIAL_UNREADABLE",
        "OPENAI_CLEANUP", "OPENAI_CANCELLED", "OPENAI_TRANSCRIBE_FAILED", "OPENAI_WORKER_FAILED", "OPENAI_RESPONSE_INVALID"]
    public static func openAICode(_ raw: String) -> String {
        if openAICodes.contains(raw) { return raw }
        switch raw {
        case "http_401", "GROQ_HTTP_401": return "OPENAI_HTTP_401"
        case "http_403", "GROQ_HTTP_403": return "OPENAI_HTTP_403"
        case "http_413", "GROQ_HTTP_413": return "OPENAI_HTTP_413"
        case "http_429", "GROQ_HTTP_429": return "OPENAI_HTTP_429"
        case "http_5xx", "GROQ_HTTP_5XX": return "OPENAI_HTTP_5XX"
        case "http_insufficient_quota": return "OPENAI_INSUFFICIENT_QUOTA"
        case "request_failed", "GROQ_REQUEST_FAILED", "LINE_WORKER_TIMEOUT": return "OPENAI_REQUEST_FAILED"
        case "CREDENTIAL_MISSING": return "OPENAI_CREDENTIAL_MISSING"
        case "CREDENTIAL_STORAGE", "CREDENTIAL_CORRUPT": return "OPENAI_CREDENTIAL_UNREADABLE"
        case "CREDENTIAL_INVALID", "GROQ_CREDENTIAL_INVALID": return "OPENAI_CREDENTIAL_INVALID"
        case "GROQ_CLEANUP", "GROQ_CLIENT_CLEANUP": return "OPENAI_CLEANUP"
        case "GROQ_CANCELLED": return "OPENAI_CANCELLED"
        case "response_invalid", "GROQ_RESPONSE_INVALID": return "OPENAI_RESPONSE_INVALID"
        case "LINE_WORKER_LAUNCH", "LINE_WORKER_IO", "LINE_WORKER_CLOSED", "LINE_WORKER_BUSY", "LINE_WORKER_INVALID", "LINE_WORKER_OVERSIZE": return "OPENAI_WORKER_FAILED"
        default: return "OPENAI_TRANSCRIBE_FAILED"
        }
    }
    public static func code(_ raw: String, provider: OnlineAPIProvider) -> String {
        if microphoneCodes.contains(raw) || localCodes.contains(raw) { return raw }
        if provider == .openai { return openAICode(safeCode(raw)) }
        if provider == .aliyunIntl, AliCode(rawValue: raw) != nil { return raw.replacingOccurrences(of: "ALI_", with: "ALI_INTL_", range: raw.startIndex..<raw.index(raw.startIndex, offsetBy: 4)) }
        return safeCode(raw)
    }
    private static func isIntlCode(_ code: String) -> Bool {
        code.hasPrefix("ALI_INTL_") && AliCode(rawValue: "ALI_" + code.dropFirst(9)) != nil
    }

    private static let workerCodeMappings: [String: String] = [
        "config_invalid": "GROQ_CONFIG_INVALID",
        "command_invalid": "GROQ_COMMAND_INVALID",
        "audio_invalid": "GROQ_AUDIO_INVALID",
        "response_invalid": "GROQ_RESPONSE_INVALID",
        "request_failed": "GROQ_REQUEST_FAILED",
        "http_401": "GROQ_HTTP_401",
        "http_403": "GROQ_HTTP_403",
        "http_413": "GROQ_HTTP_413",
        "http_429": "GROQ_HTTP_429",
        "http_5xx": "GROQ_HTTP_5XX",
    ]

    private static let workerCodes: Set<String> = [
        "LINE_WORKER_TIMEOUT", "LINE_WORKER_LAUNCH", "LINE_WORKER_IO",
        "LINE_WORKER_CLOSED", "LINE_WORKER_BUSY", "LINE_WORKER_INVALID",
        "LINE_WORKER_OVERSIZE",
    ]

    private static let clientCodes: Set<String> = [
        "GROQ_CLIENT_STATE", "GROQ_CLIENT_CLEANUP", "GROQ_CLIENT_FAILED",
    ]

    private static let credentialCodes: Set<String> = [
        "CREDENTIAL_MISSING", "CREDENTIAL_CORRUPT", "CREDENTIAL_STORAGE", "CREDENTIAL_INVALID",
    ]

    private static let lifecycleCodes: Set<String> = [
        "GROQ_CLEANUP", "GROQ_CANCELLED", "GROQ_TRANSCRIBE_FAILED",
        "GROQ_CONFIG_INVALID", "GROQ_COMMAND_INVALID", "GROQ_AUDIO_INVALID", "GROQ_RESPONSE_INVALID",
    ]

    /// "用于增强本地识别": the one failure the hybrid backend reports itself (`HybridFinalSelector.incompleteCode`),
    /// when neither recognizer had a final text in time. Any other failure it forwards is the local branch's own.
    /// A literal, so this file needs no other file to build; the self-test pins it to the selector's constant.
    private static let hybridCodes: Set<String> = ["HYBRID_FINAL_INCOMPLETE"]
    private static let microphoneCodes: Set<String> = ["MICROPHONE_NO_SOUND", "MICROPHONE_NO_CALLBACKS", "AUDIO_ROUTE_CHANGED", "AUDIO_ROUTE_REOPEN_FAILED", "INPUT_DEVICE_SELECTION_FAILED", "INPUT_DEVICE_FORMAT_UNAVAILABLE", "INPUT_DEVICE_UNAVAILABLE"]
    private static let localCodes: Set<String> = ["LOCAL_START_FAILED", "LOCAL_CAPTURE_FAILED", "LOCAL_INFERENCE_FAILED", "LOCAL_ALREADY_STARTED", "LOCAL_UNSUPPORTED_MODE", "LOCAL_CATALOG_UNAVAILABLE", "LOCAL_UNKNOWN_ROUTE", "LOCAL_APPLE_ROUTE_REFUSED", "LOCAL_MODEL_FILES_MISSING", "LOCAL_LANGUAGE_UNSUPPORTED", "LOCAL_MIC_PERMISSION_DENIED"]
}
