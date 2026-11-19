import Foundation

public enum VoiceIssueCode: String, CaseIterable, Sendable, Hashable {
    case safeInputBlocked
    case configurationInvalid
    case cloudRouteUnavailable
    case platformUnsupported
    case endpointInvalid
    case targetUnavailable
    case sendNoTarget
    case applicationExcluded
    case recognitionStartFailed
    case recognitionFailed
    /// "用于增强本地识别": neither recognizer finished in time; what was already written stays, nothing is sent.
    case recognitionIncomplete
    case microphoneNoSound
    case audioRouteChanged
    case audioRouteReopenFailed
    case apiKeyMissing
    case apiKeyInvalid
    case credentialUnreadable
    case accessDenied
    case freeQuotaExhausted
    case balanceDue
    case modelUnavailable
    case rateLimited
    case networkFailed
    case serviceUnavailable
    case responseTimeout
    case audioTooLarge
    case localWorkerFailed
    case dictationResourceBusy
    case dictationNotSettled
    case doubaoTextTimeout
    case deliveryFailed
    case eventPostFailed
    case sendStillPresent
    case sendTargetChangedBeforeReturn
    case sendPreempted
    case sendUnconfirmed
    case deliveryUnconfirmed
    case finalCopiedToClipboard
    case cancelUnconfirmed
    case targetChanged
    case explicitCancellation
    case kept
    case sent
    case nothingToSend
    case removedCurrentDictation
    case clearedCurrentInput
    case clearArmed
    case nothingToCancel
    case unsafeToCancel
    case undoSubmitted
}

public enum VoiceIssueStage: String, Sendable, Hashable {
    case selection
    case preparation
    case audio
    case backend
    case resourceRelease
    case target
    case delivery
    case send
    case cancel
}

public enum VoiceIssueSafeAction: String, Sendable, Hashable {
    case none
    case retryManually
    case refocusInput
    case openSettings
    case switchProvider
    case viewQuota
}

public enum VoiceIssueDisposition: String, Sendable, Hashable {
    case silent
    case toast
    case gestureHint
}

public enum VoiceIssueTone: String, Sendable, Hashable {
    case success
    case info
    case warning
}

public struct VoiceIssuePresentation: Sendable, Equatable {
    public let code: VoiceIssueCode
    public let stage: VoiceIssueStage
    public let safeAction: VoiceIssueSafeAction
    public let disposition: VoiceIssueDisposition
    public let message: String
    public let tone: VoiceIssueTone
    public let deduplicatesWithinSession: Bool

    public var shouldPresent: Bool { disposition != .silent }

    public init(
        code: VoiceIssueCode,
        stage: VoiceIssueStage,
        safeAction: VoiceIssueSafeAction,
        disposition: VoiceIssueDisposition,
        message: String,
        tone: VoiceIssueTone,
        deduplicatesWithinSession: Bool
    ) {
        self.code = code
        self.stage = stage
        self.safeAction = safeAction
        self.disposition = disposition
        self.message = message
        self.tone = tone
        self.deduplicatesWithinSession = deduplicatesWithinSession
    }
}

public enum VoiceIssuePresentationPolicy {
    public static let dictationNotSettledMessage = "文字还在变，这次没自动发送；看一眼没问题就按回车。"

    public static func resolve(
        code: VoiceIssueCode,
        stage: VoiceIssueStage,
        safeAction: VoiceIssueSafeAction
    ) -> VoiceIssuePresentation {
        let disposition: VoiceIssueDisposition
        let message: String
        let tone: VoiceIssueTone
        let deduplicates: Bool

        switch code {
        case .safeInputBlocked:
            disposition = .toast
            message = "此输入框隐藏文字，咻暂时无法核对写入"
            tone = .warning
            deduplicates = true
        case .configurationInvalid, .endpointInvalid:
            disposition = .toast
            message = "当前语音方案设置有误"
            tone = .warning
            deduplicates = true
        case .cloudRouteUnavailable:
            disposition = .toast
            message = "云端识别暂不可用，请切换豆包或本地"
            tone = .warning
            deduplicates = true
        case .platformUnsupported:
            disposition = .toast
            message = "Apple 系统识别需要 macOS 26，请选择其他方案"
            tone = .warning
            deduplicates = true
        case .targetUnavailable:
            disposition = .toast
            message = "此处暂时无法语音输入，请点一下输入框再试"
            tone = .warning
            deduplicates = true
        case .sendNoTarget:
            disposition = .toast
            message = "没找到输入框"
            tone = .info
            deduplicates = true
        case .applicationExcluded:
            disposition = .toast
            message = "此应用已停用语音输入，可在设置中恢复"
            tone = .warning
            deduplicates = true
        case .recognitionStartFailed:
            disposition = .toast
            message = "听写启动失败"
            tone = .warning
            deduplicates = true
        case .recognitionFailed:
            disposition = .toast
            message = "语音识别失败，请重试"
            tone = .warning
            deduplicates = true
        case .recognitionIncomplete:
            disposition = .toast
            message = "识别没完成，没有发送，请重试"
            tone = .warning
            deduplicates = true
        case .microphoneNoSound:
            disposition = .toast
            message = MicrophoneSilenceGate.message
            tone = .warning
            deduplicates = true
        case .audioRouteChanged, .audioRouteReopenFailed:
            disposition = .toast
            message = SpeechFailureDiagnostics.message(for: code == .audioRouteChanged ? "AUDIO_ROUTE_CHANGED" : "AUDIO_ROUTE_REOPEN_FAILED")
            tone = .warning
            deduplicates = true
        case .apiKeyMissing:
            disposition = .toast
            message = "请在设置中配置 API Key"
            tone = .warning
            deduplicates = true
        case .apiKeyInvalid:
            disposition = .toast
            message = "API Key 无效，请重新配置"
            tone = .warning
            deduplicates = true
        case .credentialUnreadable:
            disposition = .toast
            message = "API Key 需要重新配置"
            tone = .warning
            deduplicates = true
        case .accessDenied:
            disposition = .toast
            message = "服务未授权，请检查账号权限"
            tone = .warning
            deduplicates = true
        case .freeQuotaExhausted:
            disposition = .toast
            message = SpeechFailureDiagnostics.AliDiagnostic(code: .freeQuotaExhausted).message
            tone = .warning
            deduplicates = true
        case .balanceDue:
            disposition = .toast
            message = SpeechFailureDiagnostics.AliDiagnostic(code: .balanceDue).message
            tone = .warning
            deduplicates = true
        case .modelUnavailable:
            disposition = .toast
            message = SpeechFailureDiagnostics.AliDiagnostic(code: .modelUnavailable).message
            tone = .warning
            deduplicates = true
        case .rateLimited:
            disposition = .toast
            message = "请求过于频繁，请稍后重试"
            tone = .warning
            deduplicates = true
        case .networkFailed:
            disposition = .toast
            message = "网络连接失败"
            tone = .warning
            deduplicates = true
        case .serviceUnavailable:
            disposition = .toast
            message = "识别服务暂时不可用，请稍后重试"
            tone = .warning
            deduplicates = true
        case .responseTimeout:
            disposition = .toast
            message = "识别服务响应超时，请重试"
            tone = .warning
            deduplicates = true
        case .audioTooLarge:
            disposition = .toast
            message = "录音数据过大，请缩短录音后重试"
            tone = .warning
            deduplicates = true
        case .localWorkerFailed:
            disposition = .toast
            message = "本地识别进程异常，请重试"
            tone = .warning
            deduplicates = true
        case .dictationResourceBusy:
            disposition = .toast
            message = "上一轮还在结束，请稍后再试"
            tone = .warning
            deduplicates = true
        case .dictationNotSettled:
            disposition = .toast
            message = dictationNotSettledMessage
            tone = .warning
            deduplicates = true
        case .doubaoTextTimeout:
            disposition = .toast
            message = "豆包没出字，没发送，再推一下直接发"
            tone = .warning
            deduplicates = true
        case .deliveryFailed:
            disposition = .toast
            message = "文字写入失败，请重新点选输入框"
            tone = .warning
            deduplicates = true
        case .finalCopiedToClipboard:
            disposition = .toast
            message = "这句没写进去，已复制，按 ⌘V 粘贴。"
            tone = .warning
            deduplicates = true
        case .eventPostFailed:
            disposition = .toast
            message = "操作未能完成，请重试"
            tone = .warning
            deduplicates = true
        case .sendStillPresent:
            disposition = .toast
            message = "没发出去，文字还在"
            tone = .warning
            deduplicates = true
        case .sendTargetChangedBeforeReturn:
            disposition = .toast
            message = "没发出去：发送前点了别处，字还在原来的输入框里"
            tone = .warning
            deduplicates = true
        case .sendPreempted:
            disposition = .toast
            message = "上一次发送被打断，请查看输入框并确认结果"
            tone = .warning
            deduplicates = true
        case .deliveryUnconfirmed:
            disposition = stage == .send ? .toast : .silent
            message = stage == .send ? "没能确认文字写进去，这次没发送，请看一眼输入框" : ""
            tone = .warning
            deduplicates = stage == .send
        case .targetChanged:
            disposition = stage == .send ? .toast : .silent
            message = stage == .send ? "输入框换了，这次没发送" : ""
            tone = .warning
            deduplicates = stage == .send
        case .sendUnconfirmed, .cancelUnconfirmed, .explicitCancellation:
            disposition = .silent
            message = ""
            tone = .warning
            deduplicates = false
        case .clearArmed:
            // T13: A light disc hint, never a warning Toast or an automatic second action.
            disposition = .gestureHint
            message = "再下滑清空"
            tone = .info
            deduplicates = false
        case .unsafeToCancel:
            disposition = .gestureHint
            message = "没删掉，请手动删一下"
            tone = .warning
            deduplicates = false
        case .kept, .sent, .nothingToSend, .removedCurrentDictation,
             .clearedCurrentInput, .nothingToCancel, .undoSubmitted:
            disposition = .silent
            message = ""
            tone = [.sent, .removedCurrentDictation, .clearedCurrentInput].contains(code) ? .success : .info
            deduplicates = false
        }

        return VoiceIssuePresentation(
            code: code,
            stage: stage,
            safeAction: safeAction,
            disposition: disposition,
            message: message,
            tone: tone,
            deduplicatesWithinSession: deduplicates
        )
    }

    public static func forComposerOutcome(
        _ outcome: ComposerActionOutcome,
        action: VoiceReleaseAction
    ) -> VoiceIssuePresentation {
        switch outcome {
        case .undoSubmitted:
            return resolve(code: .undoSubmitted, stage: .cancel, safeAction: .none)
        case .deliveryFailed:
            return resolve(code: .deliveryFailed, stage: .delivery, safeAction: .refocusInput)
        case .deliveryUnconfirmed:
            if action == .send {
                return resolve(code: .deliveryUnconfirmed, stage: .send, safeAction: .refocusInput)
            }
            return resolve(code: .deliveryUnconfirmed, stage: .delivery, safeAction: .none)
        case .finalCopiedToClipboard:
            return resolve(code: .finalCopiedToClipboard, stage: .delivery, safeAction: .none)
        case .kept, .inputSubmitted:
            return resolve(code: .kept, stage: .audio, safeAction: .none)
        case .sent:
            return resolve(code: .sent, stage: .send, safeAction: .none)
        case .nothingToSend:
            return resolve(code: .nothingToSend, stage: .send, safeAction: .none)
        case .removedCurrentDictation:
            return resolve(code: .removedCurrentDictation, stage: .cancel, safeAction: .none)
        case .clearedCurrentInput:
            return resolve(code: .clearedCurrentInput, stage: .cancel, safeAction: .none)
        case .clearArmed:
            return resolve(code: .clearArmed, stage: .cancel, safeAction: .retryManually)
        case .nothingToCancel:
            return resolve(code: .nothingToCancel, stage: .cancel, safeAction: .none)
        case .targetChanged:
            if action == .send {
                return resolve(code: .targetChanged, stage: .send, safeAction: .refocusInput)
            }
            return resolve(code: .targetChanged, stage: .delivery, safeAction: .none)
        case .unsafeToCancel:
            return resolve(code: .unsafeToCancel, stage: .cancel, safeAction: .none)
        case .eventPostFailed:
            return resolve(
                code: .eventPostFailed,
                stage: action == .send ? .send : .cancel,
                safeAction: .retryManually
            )
        case .sendUnconfirmed:
            return resolve(code: .sendUnconfirmed, stage: .send, safeAction: .none)
        case .sendPreempted:
            return resolve(code: .sendPreempted, stage: .send, safeAction: .none)
        case .sendStillPresent:
            // Text remains in the target, but submission may still have
            // occurred. Do not imply that another send is safe.
            return resolve(code: .sendStillPresent, stage: .send, safeAction: .none)
        case .sendTargetChangedBeforeReturn:
            return resolve(code: .sendTargetChangedBeforeReturn, stage: .send, safeAction: .refocusInput)
        case .cancelUnconfirmed:
            return resolve(code: .cancelUnconfirmed, stage: .cancel, safeAction: .none)
        case .dictationNotSettled:
            return resolve(code: .dictationNotSettled, stage: .backend, safeAction: .retryManually)
        case .doubaoTextTimeout:
            return resolve(code: .doubaoTextTimeout, stage: .send, safeAction: .retryManually)
        }
    }

    public static func forBackendCode(_ code: String) -> VoiceIssuePresentation {
        let safeCode = SpeechFailureDiagnostics.safeCode(code)
        if safeCode.hasPrefix("OPENAI_") || safeCode.hasPrefix("ALI_INTL_") {
            let base: VoiceIssuePresentation
            if safeCode.hasPrefix("ALI_INTL_"), let ali = SpeechFailureDiagnostics.AliCode(rawValue: "ALI_" + safeCode.dropFirst(9)) {
                base = forAliDiagnostic(.init(code: ali))
            } else {
                let issue: VoiceIssueCode = safeCode.hasSuffix("HTTP_401") ? .apiKeyInvalid
                    : safeCode.hasSuffix("CREDENTIAL_MISSING") ? .apiKeyMissing
                    : safeCode.hasSuffix("INSUFFICIENT_QUOTA") ? .balanceDue
                    : safeCode.hasSuffix("REQUEST_FAILED") ? .networkFailed : .recognitionFailed
                base = resolve(code: issue, stage: .backend, safeAction: .openSettings)
            }
            return .init(code: base.code, stage: base.stage, safeAction: base.safeAction, disposition: base.disposition,
                message: SpeechFailureDiagnostics.message(for: safeCode), tone: base.tone, deduplicatesWithinSession: base.deduplicatesWithinSession)
        }
        if let ali = SpeechFailureDiagnostics.AliCode(rawValue: safeCode) {
            return forAliDiagnostic(.init(code: ali))
        }
        switch safeCode {
        case "GROQ_HTTP_401", "GROQ_CREDENTIAL_INVALID", "CREDENTIAL_INVALID":
            return resolve(code: .apiKeyInvalid, stage: .backend, safeAction: .openSettings)
        case "GROQ_HTTP_403":
            return resolve(code: .accessDenied, stage: .backend, safeAction: .openSettings)
        case "GROQ_HTTP_413":
            return resolve(code: .audioTooLarge, stage: .audio, safeAction: .retryManually)
        case "GROQ_HTTP_429":
            return resolve(code: .rateLimited, stage: .backend, safeAction: .retryManually)
        case "GROQ_HTTP_5XX":
            return resolve(code: .serviceUnavailable, stage: .backend, safeAction: .retryManually)
        case "CREDENTIAL_MISSING":
            return resolve(code: .apiKeyMissing, stage: .preparation, safeAction: .openSettings)
        case "CREDENTIAL_CORRUPT", "CREDENTIAL_STORAGE":
            return resolve(code: .credentialUnreadable, stage: .preparation, safeAction: .openSettings)
        case "GROQ_REQUEST_FAILED", "LINE_WORKER_TIMEOUT":
            return resolve(code: .networkFailed, stage: .backend, safeAction: .retryManually)
        case "LINE_WORKER_LAUNCH", "LINE_WORKER_IO", "LINE_WORKER_CLOSED",
             "LINE_WORKER_BUSY", "LINE_WORKER_INVALID", "LINE_WORKER_OVERSIZE":
            return resolve(code: .localWorkerFailed, stage: .backend, safeAction: .retryManually)
        case "GROQ_CLEANUP", "GROQ_CLIENT_CLEANUP":
            return resolve(code: .dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually)
        case "GROQ_CANCELLED":
            return resolve(code: .explicitCancellation, stage: .backend, safeAction: .none)
        case "HYBRID_FINAL_INCOMPLETE":
            return resolve(code: .recognitionIncomplete, stage: .backend, safeAction: .retryManually)
        case "MICROPHONE_NO_SOUND", "MICROPHONE_NO_CALLBACKS":
            return resolve(code: .microphoneNoSound, stage: .audio, safeAction: .retryManually)
        case "AUDIO_ROUTE_CHANGED":
            return resolve(code: .audioRouteChanged, stage: .audio, safeAction: .retryManually)
        case "AUDIO_ROUTE_REOPEN_FAILED", "INPUT_DEVICE_SELECTION_FAILED", "INPUT_DEVICE_FORMAT_UNAVAILABLE", "INPUT_DEVICE_UNAVAILABLE":
            return resolve(code: .audioRouteReopenFailed, stage: .audio, safeAction: .retryManually)
        default:
            return resolve(code: .recognitionFailed, stage: .backend, safeAction: .retryManually)
        }
    }

    private static func forAliDiagnostic(_ diagnostic: SpeechFailureDiagnostics.AliDiagnostic) -> VoiceIssuePresentation {
        let issue: VoiceIssueCode
        let stage: VoiceIssueStage
        let action: VoiceIssueSafeAction
        switch diagnostic.code {
        case .authFailed, .credentialInvalid:
            (issue, stage, action) = (.apiKeyInvalid, .backend, .openSettings)
        case .credentialMissing:
            (issue, stage, action) = (.apiKeyMissing, .preparation, .openSettings)
        case .credentialUnreadable:
            (issue, stage, action) = (.credentialUnreadable, .preparation, .openSettings)
        case .accessDenied:
            (issue, stage, action) = (.accessDenied, .backend, .openSettings)
        case .freeQuotaExhausted:
            (issue, stage, action) = (.freeQuotaExhausted, .backend, .viewQuota)
        case .balanceDue:
            (issue, stage, action) = (.balanceDue, .backend, .viewQuota)
        case .modelUnavailable:
            (issue, stage, action) = (.modelUnavailable, .backend, .switchProvider)
        case .rateLimited:
            (issue, stage, action) = (.rateLimited, .backend, .retryManually)
        case .serviceUnavailable:
            (issue, stage, action) = (.serviceUnavailable, .backend, .retryManually)
        case .networkFailed:
            (issue, stage, action) = (.networkFailed, .backend, .retryManually)
        case .timeout:
            (issue, stage, action) = (.responseTimeout, .backend, .retryManually)
        case .workerFailed:
            (issue, stage, action) = (.localWorkerFailed, .preparation, .retryManually)
        case .startFailed, .taskStartFailed:
            (issue, stage, action) = (.recognitionStartFailed, .preparation, .retryManually)
        case .microphonePermissionDenied:
            (issue, stage, action) = (.recognitionStartFailed, .audio, .openSettings)
        case .backendState:
            (issue, stage, action) = (.recognitionStartFailed, .preparation, .openSettings)
        case .endpointInvalid:
            (issue, stage, action) = (.endpointInvalid, .preparation, .openSettings)
        case .cleanup:
            (issue, stage, action) = (.dictationResourceBusy, .resourceRelease, .retryManually)
        case .cloudRevoked:
            (issue, stage, action) = (.cloudRouteUnavailable, .backend, .switchProvider)
        case .invalidRequest, .streamFailed, .clientState, .clientFailed,
             .protocolInvalid, .protocolOversize, .taskFailed:
            (issue, stage, action) = (.recognitionFailed, .backend, .retryManually)
        }
        let base = resolve(code: issue, stage: stage, safeAction: action)
        return VoiceIssuePresentation(
            code: base.code, stage: base.stage, safeAction: base.safeAction,
            disposition: base.disposition, message: diagnostic.message, tone: base.tone,
            deduplicatesWithinSession: base.deduplicatesWithinSession
        )
    }

    /// Toasts are owned by the status callback. Gesture hints are shown by
    /// the completion callback, while silent or deduplicated issues clear any
    /// stale listening/failure status.
    public static func runtimeStatus(
        for presentation: VoiceIssuePresentation,
        isPresentationAllowed: Bool
    ) -> VoicePointerRuntimeStatus {
        guard isPresentationAllowed,
              presentation.shouldPresent,
              presentation.disposition == .toast else {
            return .idle
        }
        return .failed(presentation.message)
    }
}

public struct VoiceIssuePresentationGate: Sendable {
    private var sessionID: UUID?
    private var seenCodes: Set<VoiceIssueCode> = []
    /// Only F5 spans gestures. Entries expire after ten seconds; nothing is persisted.
    private var noTargetHintTimes: [String: TimeInterval] = [:]

    public init() {}

    public mutating func beginSession(_ sessionID: UUID) {
        guard self.sessionID != sessionID else { return }
        self.sessionID = sessionID
        seenCodes.removeAll(keepingCapacity: true)
    }

    public mutating func shouldPresent(
        _ presentation: VoiceIssuePresentation,
        sessionID: UUID,
        applicationBundleID: String? = nil,
        monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        beginSession(sessionID)
        guard presentation.shouldPresent else { return false }
        if presentation.deduplicatesWithinSession, seenCodes.contains(presentation.code) { return false }
        if presentation.code == .sendNoTarget {
            let key = applicationBundleID ?? "unknown"
            noTargetHintTimes = noTargetHintTimes.filter { monotonicTime - $0.value < 10 }
            guard noTargetHintTimes[key] == nil else { return false }
            noTargetHintTimes[key] = monotonicTime
        }
        if presentation.deduplicatesWithinSession { seenCodes.insert(presentation.code) }
        return true
    }
}
