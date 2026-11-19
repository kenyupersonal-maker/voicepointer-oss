import Foundation

public enum OnlineAPIProvider: String, Codable, CaseIterable, Sendable {
    case aliyunBailian, aliyunIntl, groq, openai, siliconflow

    public var isAliyun: Bool { self == .aliyunBailian || self == .aliyunIntl }
    public var supportsEnhanceLocal: Bool { true }
    public var defaultEndpoint: String {
        switch self {
        case .aliyunBailian: AliEndpoint.defaultURLString
        case .aliyunIntl: AliEndpoint.internationalURLString
        case .groq: "https://api.groq.com/openai/v1"
        case .openai: "https://api.openai.com/v1"
        case .siliconflow: "https://api.siliconflow.cn/v1"
        }
    }
    /// Priority only. A returned model list is always intersected with this list.
    public var modelIDs: [String] {
        switch self {
        case .aliyunBailian, .aliyunIntl:
            ["qwen-audio-3.1-asr-flash-streaming", "qwen-audio-3.0-asr-flash-streaming", "fun-asr-realtime", "fun-asr-realtime-2026-02-28", "paraformer-realtime-v2", "paraformer-realtime-v1"]
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .openai: ["gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]
        case .siliconflow: ["FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR"]
        }
    }
}

/// Credential-free value. Persistence, legacy migration and route changes belong to phase E.
public struct OnlineAPIConfiguration: Codable, Hashable, Sendable {
    public var provider: OnlineAPIProvider
    public var modelID: String
    public var endpointOverride: String?
    public var credentialRevision: String

    public init(provider: OnlineAPIProvider, modelID: String, endpointOverride: String? = nil,
                credentialRevision: String) {
        self.provider = provider
        self.modelID = modelID
        self.endpointOverride = endpointOverride
        self.credentialRevision = credentialRevision
    }

    public var consentID: String { provider.isAliyun ? "aliyun-beijing" : provider.rawValue }
    public var routeID: String {
        switch provider {
        case .aliyunBailian, .aliyunIntl: "aliyun"
        case .groq: modelID == "whisper-large-v3" ? "groq-v3" : "groq-turbo"
        case .openai: modelID == "gpt-4o-mini-transcribe" ? "openai-mini-transcribe" : "openai-transcribe"
        case .siliconflow: "siliconflow-sensevoice"
        }
    }
    public func validatedEndpoint() throws -> URL {
        guard provider.modelIDs.contains(modelID), !credentialRevision.isEmpty else { throw OnlineAPIEndpointError.invalid }
        return try OnlineAPIEndpoint.resolve(provider: provider, override: endpointOverride)
    }
    public static let cloudRouteIDs: Set<String> = ["aliyun", "groq-v3", "groq-turbo", "openai-transcribe", "openai-mini-transcribe", "siliconflow-sensevoice"]
}

public enum OnlineAPISetupPurpose: Sendable { case route, enhanceLocal, configure }
public enum OnlineAPISetupContext: Sendable { case onboarding, settings }
public enum OnlineAPISetupPage: Sendable { case form, guide }

public enum OnlineAPIEndpointError: Error, Sendable { case invalid }

public enum OnlineAPIEndpoint {
    /// Resolve and validate before a key can cross a pipe. No redirects or arbitrary paths.
    public static func resolve(provider: OnlineAPIProvider, override: String?) throws -> URL {
        let raw = (override?.isEmpty == false) ? override! : provider.defaultEndpoint
        guard raw.utf8.count <= 512, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && (33...126).contains($0.value) }),
              !raw.contains("%"), !raw.contains("\\"),
              let c = URLComponents(string: raw), let host = c.host,
              host == host.lowercased(), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.port == nil || c.port == 443,
              let url = c.url, url.absoluteString == raw else { throw OnlineAPIEndpointError.invalid }
        if provider.isAliyun {
            let endpoint = try AliEndpoint(raw)
            if provider == .aliyunIntl {
                guard host == "dashscope-intl.aliyuncs.com" else { throw OnlineAPIEndpointError.invalid }
            } else {
                guard host != "dashscope-intl.aliyuncs.com" else { throw OnlineAPIEndpointError.invalid }
            }
            return endpoint.url
        }
        let expectedHost = provider == .groq ? "api.groq.com" : provider == .siliconflow ? "api.siliconflow.cn" : "api.openai.com"
        let expectedPath = provider == .groq ? "/openai/v1" : "/v1"
        guard c.scheme == "https", host == expectedHost, c.percentEncodedPath == expectedPath else {
            throw OnlineAPIEndpointError.invalid
        }
        return url
    }
}
