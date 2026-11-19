// AliEndpoint.swift
// Pure value type: strict validation of Ali real-time ASR WebSocket endpoint URLs.
// No I/O, no credentials, no network, no logging, no WorkspaceId values embedded.

import Foundation

public struct AliEndpoint: Sendable, Equatable {
    public let url: URL

    public init(_ raw: String) throws {
        // 1. ASCII printable, no leading/trailing whitespace, length guard.
        guard raw.count <= 512, !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && ($0.value >= 33 && $0.value <= 126) })
        else { throw AliEndpointError.invalid }
        // Reject backslash so URL cannot normalize a path.
        guard !raw.contains("\\"), !raw.contains("%") else { throw AliEndpointError.invalid }

        guard let comps = URLComponents(string: raw) else { throw AliEndpointError.invalid }

        // 2. Scheme, authority pieces, query, fragment.
        guard let scheme = comps.scheme, scheme == "wss",
              scheme.unicodeScalars.allSatisfy({ $0.isASCII })
        else { throw AliEndpointError.invalid }
        guard comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil
        else { throw AliEndpointError.invalid }

        guard comps.port == nil || comps.port == 443 else { throw AliEndpointError.invalid }

        // 3. Host: lowercase ASCII, exact match against one of the allowed shapes.
        guard let host = comps.host, host == host.lowercased(),
              host.unicodeScalars.allSatisfy({ $0.isASCII })
        else { throw AliEndpointError.invalid }

        if host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" {
            // legacy official endpoint
        } else if host.hasSuffix(".cn-beijing.maas.aliyuncs.com") {
            let suffix = ".cn-beijing.maas.aliyuncs.com"
            let label = String(host.dropLast(suffix.count))
            // Single workspace label only: no extra dots allowed.
            guard !label.contains("."),
                  (1...63).contains(label.count),
                  label.unicodeScalars.allSatisfy({
                      ($0.value >= 97 && $0.value <= 122)
                          || ($0.value >= 48 && $0.value <= 57)
                          || $0 == "-"
                  }),
                  let first = label.first, let last = label.last,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber
            else { throw AliEndpointError.invalid }
        } else {
            throw AliEndpointError.invalid
        }

        // 4. Path must be exactly the official inference path; percent-encoded variants rejected.
        guard comps.percentEncodedPath == "/api-ws/v1/inference" else { throw AliEndpointError.invalid }

        // 5. Round-trip: reconstructed URL must equal raw (explicit :443 allowed).
        guard let url = comps.url else { throw AliEndpointError.invalid }
        let authority = String(raw.dropFirst(6).prefix { $0 != "/" })
        guard authority == host || authority == host + ":443", url.absoluteString == raw else {
            throw AliEndpointError.invalid
        }

        self.url = url
    }

    public static let defaultURLString = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    public static let internationalURLString = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
    /// Only domestic Aliyun connections bypass the system proxy; no system preference is changed.
    public var prefersDirectConnection: Bool {
        url.host == "dashscope.aliyuncs.com" || url.host?.hasSuffix(".cn-beijing.maas.aliyuncs.com") == true
    }
}

public enum AliEndpointError: Error {
    case invalid
}
