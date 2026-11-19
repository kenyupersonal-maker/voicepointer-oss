import Foundation
/// Evidence from one upstream response. A WebSocket task error never borrows
/// the HTTP upgrade status. Unknown codes and response bodies are not retained.
public struct AliFailureEvidence: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case httpResponse, webSocketTask }
    public enum ProviderCode: String, Codable, Sendable {
        case invalidAPIKey = "InvalidApiKey"
        case invalidAPIKeyLowercase = "invalid_api_key"
        case arrearage = "Arrearage"
        case freeTierOnly = "AllocationQuota.FreeTierOnly"
        case unpurchased = "AccessDenied.Unpurchased"
        case modelAccessDenied = "Model.AccessDenied"
        case rateQuota = "Throttling.RateQuota"
        case burstRate = "Throttling.BurstRate"
        case allocationQuota = "Throttling.AllocationQuota"
        case concurrency = "Throttling.Concurrency"
        case modelNotFound = "ModelNotFound"
        case modelNotFoundLowercase = "model_not_found"
        case modelUnavailable = "ModelUnavailable"
        case clientError = "CLIENT_ERROR"
    }

    public let source: Source
    public let httpStatus: Int?
    public let providerCode: ProviderCode?

    private init(source: Source, httpStatus: Int?, providerCode: ProviderCode?) {
        self.source = source
        self.httpStatus = httpStatus
        self.providerCode = providerCode
    }

    /// The caller must provide the body delivered with this exact HTTP response.
    /// No extra request is issued to obtain a missing body.
    public static func httpResponse(_ response: HTTPURLResponse, body: Data?) -> Self? {
        guard (400...599).contains(response.statusCode) else { return nil }
        var code: ProviderCode?
        if let body, body.count <= 65_536,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let raw = object["code"] as? String {
            code = ProviderCode(rawValue: raw)
        }
        return Self(source: .httpResponse, httpStatus: response.statusCode, providerCode: code)
    }

    static func httpStatusOnly(_ status: Int) -> Self? {
        guard (400...599).contains(status) else { return nil }
        return Self(source: .httpResponse, httpStatus: status, providerCode: nil)
    }

    static func webSocketTask(_ raw: String?) -> Self {
        Self(source: .webSocketTask, httpStatus: nil,
             providerCode: raw.flatMap(ProviderCode.init(rawValue:)))
    }

    public var confirmsFreeQuotaExhaustion: Bool {
        source == .httpResponse && httpStatus == 403 && providerCode == .freeTierOnly
    }

    private enum CodingKeys: String, CodingKey { case source, httpStatus, providerCode }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        source = try fields.decode(Source.self, forKey: .source)
        httpStatus = try fields.decodeIfPresent(Int.self, forKey: .httpStatus)
        providerCode = try fields.decodeIfPresent(ProviderCode.self, forKey: .providerCode)
        let valid: Bool
        switch source {
        case .httpResponse: valid = httpStatus.map { (400...599).contains($0) } ?? false
        case .webSocketTask: valid = httpStatus == nil
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: fields,
                                                  debugDescription: "Invalid Ali failure evidence shape")
        }
    }
}

/// Finite error vocabulary for Alibaba (Bailian) realtime ASR service failures.
/// Mapping is exact; unrecognized or nil codes become `streamFailed` without preserving raw text.
public struct AliServiceFailure: Error, Sendable, Equatable {
    public enum Code: String, CaseIterable, Sendable {
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
    }

    public let code: Code
    public let evidence: AliFailureEvidence?

    public init(_ code: Code, evidence: AliFailureEvidence? = nil) {
        self.code = code
        self.evidence = evidence
    }

    /// Exact finite mapping from upstream service code strings. Raw text is never preserved.
    public static func fromServiceCode(_ raw: String?) -> Self {
        let classified = classifyServiceCode(raw)
        return AliServiceFailure(classified.code, evidence: .webSocketTask(raw))
    }

    private static func classifyServiceCode(_ raw: String?) -> Self {
        switch raw {
        case "InvalidApiKey", "invalid_api_key":
            return AliServiceFailure(.authFailed)
        case "Arrearage":
            return AliServiceFailure(.balanceDue)
        case "AllocationQuota.FreeTierOnly":
            return AliServiceFailure(.freeQuotaExhausted)
        case "AccessDenied.Unpurchased", "Model.AccessDenied":
            return AliServiceFailure(.accessDenied)
        case "Throttling.RateQuota", "Throttling.BurstRate",
             "Throttling.AllocationQuota", "Throttling.Concurrency":
            return AliServiceFailure(.rateLimited)
        case "ModelNotFound", "model_not_found", "ModelUnavailable":
            return AliServiceFailure(.modelUnavailable)
        case "CLIENT_ERROR":
            return AliServiceFailure(.invalidRequest)
        default:
            return AliServiceFailure(.streamFailed)
        }
    }

    public static func fromHTTPStatus(_ status: Int) -> Self {
        AliServiceFailure(classifyHTTPStatus(status).code, evidence: .httpStatusOnly(status))
    }

    /// Preserve only bounded, whitelisted fields from this one response.
    public static func fromHTTPResponse(_ response: HTTPURLResponse, body: Data?) -> Self {
        let evidence = AliFailureEvidence.httpResponse(response, body: body)
        let code: Code
        if let providerCode = evidence?.providerCode {
            if providerCode == .freeTierOnly {
                code = evidence?.confirmsFreeQuotaExhaustion == true ? .freeQuotaExhausted : classifyHTTPStatus(response.statusCode).code
            } else {
                code = classifyServiceCode(providerCode.rawValue).code
            }
        } else {
            code = classifyHTTPStatus(response.statusCode).code
        }
        return AliServiceFailure(code, evidence: evidence)
    }

    private static func classifyHTTPStatus(_ status: Int) -> Self {
        switch status {
        case 401: return AliServiceFailure(.authFailed)
        case 403: return AliServiceFailure(.accessDenied)
        case 408: return AliServiceFailure(.timeout)
        case 429: return AliServiceFailure(.rateLimited)
        case 500...599: return AliServiceFailure(.serviceUnavailable)
        default: return AliServiceFailure(.streamFailed)
        }
    }

    /// Classify a transport error. HTTP status, when provided, wins after typed preservation.
    public static func transport(_ error: any Error, httpStatus: Int? = nil) -> Self {
        if let ali = error as? AliServiceFailure { return ali }
        if let status = httpStatus, status >= 400 { return fromHTTPStatus(status) }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return AliServiceFailure(.timeout) }
            return AliServiceFailure(.networkFailed)
        }
        return AliServiceFailure(.streamFailed)
    }
}
