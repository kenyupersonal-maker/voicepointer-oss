import Foundation

/// Official Beijing workspace API base or exact catalog URL. Both produce the
/// same canonical catalog GET URL; no user's workspace is built in.
/// Documentation: https://help.aliyun.com/zh/model-studio/list-models
/// Billing: https://help.aliyun.com/zh/model-studio/model-usage-statistics
/// A catalog GET creates no inference task (bounded inference from the documented
/// operation). Neither document explicitly promises a free catalog, ASR access,
/// remaining quota or successful speech recognition.
public struct CloudModelCatalogEndpoint: Sendable, Equatable {
    public let modelsURL: URL
    public init?(address: String) {
        guard address.utf8.count <= 256,
              let parts = URLComponents(string: address),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host,
              host.range(of: #"^ws-[a-z0-9]{1,60}\.cn-beijing\.maas\.aliyuncs\.com$"#,
                         options: .regularExpression) != nil,
              ["/api/v1", "/api/v1/models"].contains(parts.percentEncodedPath),
              address == "https://\(host)\(parts.percentEncodedPath)",
              let url = URL(string: "https://\(host)/api/v1/models") else { return nil }
        modelsURL = url
    }
}
