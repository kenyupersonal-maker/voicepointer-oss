import Foundation
import VoicePointerCore

@MainActor
enum CloudModelCatalogChecks {
    struct Report {
        var checks = 0
        var fakeKeyReads = 0
        var fakeRequests = 0
        var failures: [String] = []
    }
    static func run() async -> Report {
        var report = Report()
        func expect(_ value: Bool, _ label: String) {
            report.checks += 1
            if !value { report.failures.append(label) }
        }
        let address = "https://ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1/models"
        let endpoint = CloudModelCatalogEndpoint(address: address)!
        let baseAddress = "https://ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1"
        let baseEndpoint = CloudModelCatalogEndpoint(address: baseAddress)!
        expect(endpoint.modelsURL.absoluteString == address, "exact official catalog")
        expect(baseEndpoint == endpoint, "API base appends models once; direct endpoint remains identical")
        for invalid in ["", "http://ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1/models",
            "https://ws-synthetic.cn-shanghai.maas.aliyuncs.com/api/v1/models",
            "https://ws-synthetic.cn-beijing.maas.aliyuncs.com.evil.example/api/v1/models",
            "https://dashscope.aliyuncs.com/api/v1/models", "https://other.example/api/v1/models",
            "https://ws-synthetic.cn-beijing.maas.aliyuncs.com:443/api/v1/models",
            "https://user@ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1/models",
            "https://user:secret@ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1/models",
            "https://@ws-synthetic.cn-beijing.maas.aliyuncs.com/api/v1/models",
            address + "?", address + "?token=synthetic", address + "#", address + "/",
            address.replacingOccurrences(of: "models", with: "%6dodels"),
            address.replacingOccurrences(of: "/api/v1/models", with: "/api/v1/../v1/models"),
            address.replacingOccurrences(of: "ws-synthetic", with: "WS-synthetic"),
            address.replacingOccurrences(of: "models", with: "run-task"),
            address.replacingOccurrences(of: "models", with: "StartTranscription"),
            address + "/models", " " + address, address + "\n",
            baseAddress + "/", baseAddress + "?", baseAddress + "?page_no=2", baseAddress + "#",
            baseAddress.replacingOccurrences(of: "https:", with: "http:"),
            baseAddress.replacingOccurrences(of: "ws-synthetic", with: "user@ws-synthetic"),
            baseAddress.replacingOccurrences(of: "ws-synthetic", with: "user:secret@ws-synthetic"),
            baseAddress.replacingOccurrences(of: ".com/", with: ".com:443/"),
            baseAddress.replacingOccurrences(of: ".com/", with: ".com.evil.example/"),
            baseAddress.replacingOccurrences(of: "cn-beijing", with: "cn-shanghai"),
            baseAddress.replacingOccurrences(of: "/api/v1", with: "/api/%76%31"),
            baseAddress.replacingOccurrences(of: "/api/v1", with: "/api/./v1"),
            baseAddress.replacingOccurrences(of: "/api/v1", with: "/api/v1/../v1"),
            baseAddress.replacingOccurrences(of: "ws-synthetic", with: "WS-synthetic"),
            " " + baseAddress, baseAddress + "\n"] {
            expect(CloudModelCatalogEndpoint(address: invalid) == nil, "reject noncanonical catalog \(report.checks)")
        }
        var preference: String? = address
        var preferenceWrites = 0
        let store = CloudModelCatalogEndpointStore(read: { preference }, write: { preference = $0; preferenceWrites += 1 })
        let first = store.snapshot
        expect(store.save(address: "https://other.example/api/v1/models") == nil && preferenceWrites == 0 && store.isCurrent(first),
               "invalid endpoint does not write preferences")
        store.invalidate()
        expect(!store.isCurrent(first), "edit/cancel invalidates old endpoint even without preference write")
        let saved = store.save(address: baseAddress)!
        expect(preferenceWrites == 1 && preference == address && store.isCurrent(saved), "base persists canonical nonsecret models URL")
        _ = store.save(address: address)
        expect(!store.isCurrent(saved), "same-address save cannot revive old endpoint revision")

        let probe = CatalogFakeProbe()
        func catalogBody(_ envelope: [String: Any] = [:], page: [String: Any] = [:]) -> Data {
            var output: [String: Any] = ["total": 1, "page_no": 1, "page_size": 20,
                                        "models": [["model": "synthetic-model"]]]
            output.merge(page) { _, new in new }
            var root: [String: Any] = ["success": true, "code": NSNull(), "message": NSNull(), "output": output]
            root.merge(envelope) { _, new in new }
            return try! JSONSerialization.data(withJSONObject: root)
        }
        let success = catalogBody()
        // Public example's envelope, IDs, pagination and deepest price shape;
        // synthetic metadata is never a claim about current model availability.
        let officialExample = catalogBody(page: ["total": 168, "page_size": 10, "models": [
            ["model": "qwen3-max", "name": "Synthetic example", "features": ["function-calling"],
             "prices": [["range_name": "Default", "prices": [["type": "input_token", "price": "2", "price_unit": "synthetic"]]]],
             "published_time": NSNull(), "inference_metadata": ["request_modality": ["Text"], "response_modality": ["Text"]],
             "model_info": ["context_window": 131072, "max_reasoning_tokens": NSNull()]],
            ["model": "qwen-image-max", "published_time": NSNull()]
        ]])
        typealias Outcome = CloudModelCatalogVerifier.Outcome
        let responseCases: [(String, Int, URL, Data, Outcome)] = [
            ("authentication/catalog success", 200, endpoint.modelsURL, success, .authenticated),
            ("official example shape and first-page pagination", 200, endpoint.modelsURL, officialExample, .authenticated),
            ("empty catalog does not claim ASR", 200, endpoint.modelsURL, catalogBody(page: ["total": 0, "models": []]), .authenticated),
            ("false success with key error", 200, endpoint.modelsURL, Data(#"{"success":false,"code":"InvalidApiKey","message":"synthetic error","output":null}"#.utf8), .failed(.rejectedKey)),
            ("false success with workspace error", 200, endpoint.modelsURL, catalogBody(["success": false, "code": "Workspace.AccessDenied"]), .failed(.accessDenied)),
            ("false success with unknown error", 200, endpoint.modelsURL, catalogBody(["success": false, "code": "SyntheticFailure"]), .failed(.service)),
            ("false success without error details", 200, endpoint.modelsURL, Data(#"{"success":false}"#.utf8), .failed(.service)),
            ("401", 401, endpoint.modelsURL, Data(), .failed(.rejectedKey)),
            ("403 catalog access only", 403, endpoint.modelsURL, Data(), .failed(.accessDenied)),
            ("service status", 500, endpoint.modelsURL, Data(), .failed(.service)),
            ("same-domain redirect", 302, endpoint.modelsURL, Data(), .failed(.redirect)),
            ("cross-domain redirect", 307, endpoint.modelsURL, Data(), .failed(.redirect)),
            ("unexpected final host", 200, URL(string: "https://other.example/api/v1/models")!, success, .failed(.endpointMismatch)),
            ("unexpected final base path", 200, URL(string: baseAddress)!, success, .failed(.endpointMismatch)),
            ("oversize official envelope", 200, endpoint.modelsURL, catalogBody(["request_id": String(repeating: "x", count: CloudModelCatalogVerifier.maximumBodyBytes)]), .failed(.bodyTooLarge)),
            ("invalid JSON", 200, endpoint.modelsURL, Data("not JSON".utf8), .failed(.invalidSchema)),
            ("array root", 200, endpoint.modelsURL, Data("[]".utf8), .failed(.invalidSchema)),
            ("missing success", 200, endpoint.modelsURL, Data(#"{"output":{"models":[]}}"#.utf8), .failed(.invalidSchema)),
            ("numeric success is not a boolean", 200, endpoint.modelsURL, catalogBody(["success": 1]), .failed(.invalidSchema)),
            ("string success is not a boolean", 200, endpoint.modelsURL, catalogBody(["success": "true"]), .failed(.invalidSchema)),
            ("missing output", 200, endpoint.modelsURL, Data(#"{"success":true,"code":null,"message":null}"#.utf8), .failed(.invalidSchema)),
            ("null output", 200, endpoint.modelsURL, catalogBody(["output": NSNull()]), .failed(.invalidSchema)),
            ("conflicting success and error code", 200, endpoint.modelsURL, catalogBody(["code": "InvalidApiKey"]), .failed(.invalidSchema)),
            ("conflicting success and error message", 200, endpoint.modelsURL, catalogBody(["message": "synthetic error"]), .failed(.invalidSchema)),
            ("wrong code type", 200, endpoint.modelsURL, catalogBody(["code": 0]), .failed(.invalidSchema)),
            ("error masquerading as official catalog", 200, endpoint.modelsURL, catalogBody(["error": NSNull()]), .failed(.invalidSchema)),
            ("unrelated OpenAI nonempty list", 200, endpoint.modelsURL, Data(#"{"object":"list","data":[{"id":"synthetic-model"}]}"#.utf8), .failed(.invalidSchema)),
            ("unrelated OpenAI empty list", 200, endpoint.modelsURL, Data(#"{"data":[]}"#.utf8), .failed(.invalidSchema)),
            ("wrong model list type", 200, endpoint.modelsURL, catalogBody(page: ["models": "synthetic"]), .failed(.invalidSchema)),
            ("wrong model row type", 200, endpoint.modelsURL, catalogBody(page: ["models": ["synthetic"]]), .failed(.invalidSchema)),
            ("unrelated ID field inside official output", 200, endpoint.modelsURL, catalogBody(page: ["models": [["id": "synthetic"]]]), .failed(.invalidSchema)),
            ("model ID type", 200, endpoint.modelsURL, catalogBody(page: ["models": [["model": 42]]]), .failed(.invalidSchema)),
            ("empty ID", 200, endpoint.modelsURL, catalogBody(page: ["models": [["model": ""]]]), .failed(.invalidSchema)),
            ("ID controls", 200, endpoint.modelsURL, catalogBody(page: ["models": [["model": "synthetic\n"]]]), .failed(.invalidSchema)),
            ("ID length bound", 200, endpoint.modelsURL, catalogBody(page: ["models": [["model": String(repeating: "x", count: 257)]]]), .failed(.invalidSchema)),
            ("model count bound", 200, endpoint.modelsURL, catalogBody(page: ["total": 1025, "page_size": 1025, "models": Array(repeating: ["model": "synthetic"], count: CloudModelCatalogVerifier.maximumModels + 1)]), .failed(.invalidSchema)),
            ("large total does not require extra pages", 200, endpoint.modelsURL, catalogBody(page: ["total": 10000]), .authenticated),
            ("unrequested later page", 200, endpoint.modelsURL, catalogBody(page: ["page_no": 2]), .failed(.invalidSchema)),
            ("zero page number", 200, endpoint.modelsURL, catalogBody(page: ["page_no": 0]), .failed(.invalidSchema)),
            ("zero page size", 200, endpoint.modelsURL, catalogBody(page: ["page_size": 0]), .failed(.invalidSchema)),
            ("negative total", 200, endpoint.modelsURL, catalogBody(page: ["total": -1]), .failed(.invalidSchema)),
            ("fractional pagination", 200, endpoint.modelsURL, catalogBody(page: ["page_no": 1.5]), .failed(.invalidSchema)),
            ("boolean pagination", 200, endpoint.modelsURL, catalogBody(page: ["total": true]), .failed(.invalidSchema)),
            ("null pagination", 200, endpoint.modelsURL, catalogBody(page: ["page_size": NSNull()]), .failed(.invalidSchema)),
            ("string pagination", 200, endpoint.modelsURL, catalogBody(page: ["page_no": "1"]), .failed(.invalidSchema)),
            ("rows exceed page size", 200, endpoint.modelsURL, catalogBody(page: ["total": 2, "page_size": 1, "models": [["model": "synthetic-a"], ["model": "synthetic-b"]]]), .failed(.invalidSchema)),
            ("rows exceed total", 200, endpoint.modelsURL, catalogBody(page: ["total": 0]), .failed(.invalidSchema)),
            ("empty first page contradicts total", 200, endpoint.modelsURL, catalogBody(page: ["models": []]), .failed(.invalidSchema)),
            ("nesting bound", 200, endpoint.modelsURL, Data((String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9)).utf8), .failed(.invalidSchema))
        ]
        for (label, status, url, body, expected) in responseCases {
            let outcome = await CloudModelCatalogVerifier.run(endpoint: endpoint,
                readKey: { await probe.readFakeKey() }, transport: { request in
                    await probe.record(request, expectedURL: endpoint.modelsURL)
                    return .init(status: status, url: url, body: body)
                })
            expect(outcome == expected, label)
        }
        let canonical = await CloudModelCatalogVerifier.run(endpoint: baseEndpoint,
            readKey: { await probe.readFakeKey() }, transport: { request in
                await probe.record(request, expectedURL: endpoint.modelsURL)
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            })
        expect(canonical == .authenticated, "API base dispatches only one canonical models GET")
        for (code, expected) in [(URLError.Code.notConnectedToInternet, Outcome.failed(.network)), (.timedOut, .failed(.timeout))] {
            let outcome = await CloudModelCatalogVerifier.run(endpoint: endpoint,
                readKey: { await probe.readFakeKey() }, transport: { request in
                    await probe.record(request, expectedURL: endpoint.modelsURL); throw URLError(code)
                })
            expect(outcome == expected, "finite network/timeout outcome")
        }
        let malformed = await CloudModelCatalogVerifier.run(endpoint: endpoint,
            readKey: { await probe.recordReadAttempt(); return Data("sk-synthetic\r\ninjection".utf8) }, transport: { request in
                await probe.record(request, expectedURL: endpoint.modelsURL)
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            })
        expect(malformed == .failed(.keyUnreadable), "reject header injection before transport")
        for error in [CredentialError.missing, .corrupt] {
            let outcome = await CloudModelCatalogVerifier.run(endpoint: endpoint, readKey: { await probe.recordReadAttempt(); throw error }, transport: { _ in
                throw CloudModelCatalogVerifier.Failure.service
            })
            let expected: Outcome = error == .missing ? .failed(.noKey) : .failed(.keyUnreadable)
            expect(outcome == expected, "missing/unreadable synthetic helper")
        }
        let staleAfterRead = CatalogFakeProbe()
        let stale = await CloudModelCatalogVerifier.run(endpoint: endpoint,
            readKey: { let key = await staleAfterRead.readFakeKey(); await staleAfterRead.invalidate(); return key },
            transport: { request in
                await staleAfterRead.record(request, expectedURL: endpoint.modelsURL)
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            }, isCurrent: { await staleAfterRead.current })
        let staleRequests = await staleAfterRead.requestCount
        expect(stale == .cancelled && staleRequests == 0, "late credential epoch blocks GET")
        let delayed = CatalogFakeGate()
        let lateEndpoint = CatalogFakeProbe()
        let lateTask = Task {
            await CloudModelCatalogVerifier.run(endpoint: endpoint, readKey: { await lateEndpoint.readFakeKey() }, transport: { request in
                await lateEndpoint.record(request, expectedURL: endpoint.modelsURL); await delayed.suspend()
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            }, isCurrent: { await lateEndpoint.current })
        }
        await delayed.waitUntilEntered(); await lateEndpoint.invalidate(); await delayed.release()
        expect(await lateTask.value == .cancelled, "endpoint mutation discards late catalog success")
        let cancelledGate = CatalogFakeGate()
        let cancelTask = Task {
            await CloudModelCatalogVerifier.run(endpoint: endpoint, readKey: { await probe.readFakeKey() }, transport: { request in
                await probe.record(request, expectedURL: endpoint.modelsURL); await cancelledGate.suspend()
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            })
        }
        await cancelledGate.waitUntilEntered(); cancelTask.cancel()
        expect(await cancelTask.value == .cancelled, "cancel unresponsive fake transport promptly")
        await cancelledGate.release()
        let timedGate = CatalogFakeGate()
        let timed = await CloudModelCatalogVerifier.run(endpoint: endpoint, timeout: 0.05,
            readKey: { await probe.readFakeKey() }, transport: { request in
                await probe.record(request, expectedURL: endpoint.modelsURL); await timedGate.suspend()
                return .init(status: 200, url: endpoint.modelsURL, body: success)
            })
        expect(timed == .failed(.timeout), "deadline does not await stuck fake transport")
        await timedGate.release()

        // No URLSession is constructed for invalid input, even if a future
        // caller bypasses the typed endpoint and calls the transport directly.
        var getWithBody = URLRequest(url: endpoint.modelsURL)
        getWithBody.httpBody = Data("synthetic".utf8)
        var getWithStream = URLRequest(url: endpoint.modelsURL)
        getWithStream.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        for request in [URLRequest(url: URL(string: "https://other.example/api/v1/models")!),
                        URLRequest(url: URL(string: baseAddress)!), postRequest(endpoint.modelsURL), getWithBody, getWithStream] {
            do { _ = try await CloudModelCatalogVerifier.urlSessionTransport(request); expect(false, "transport rejects noncatalog request") }
            catch { expect(error as? CloudModelCatalogVerifier.Failure == .endpointMismatch, "transport boundary, real requests zero") }
        }
        let fence = CloudCatalogAuthorizationFence(), ticket = UUID()
        expect(fence.whileCurrent(ticket) { true } == nil, "arbitrary authorization ticket rejected")
        let accepted = fence.ticket
        expect(fence.whileCurrent(accepted) { true } == true, "live confirmation fence")
        fence.invalidate()
        expect(fence.whileCurrent(accepted) { true } == nil, "stale confirmation fence")
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CatalogGateSynthetic-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: root.appendingPathComponent("state.json")))
            let identity = try CloudEntry.makeIdentity(credentialRevision: "synthetic-catalog-revision")
            let refused = await gate.confirmCatalogSetup(identity: identity, fence: fence, ticket: accepted)
            expect(refused == .failed && !FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path),
                   "stale queued gate confirmation writes nothing")
            let confirmed = await gate.confirmCatalogSetup(identity: identity, fence: fence, ticket: fence.ticket)
            let snapshot = await gate.snapshot(for: identity)
            expect(confirmed == .confirmed && snapshot?.policy == .freeOnly && snapshot?.guardEvidence == .userConfirmed,
                   "K06 still records only free-only/user-console evidence")
            expect(CloudEntryStatus.confirmationLifetime == 30 * 24 * 3600 && CloudEntryStatus(snapshot: snapshot).isConfirmed,
                   "K06 confirmation eligibility/lifetime unchanged")
        } catch { expect(false, "synthetic gate fixture unavailable") }
        let totals = await probe.totals
        let extra1 = await staleAfterRead.totals, extra2 = await lateEndpoint.totals
        report.fakeKeyReads = totals.0 + extra1.0 + extra2.0
        report.fakeRequests = totals.1 + extra1.1 + extra2.1
        expect(totals.2.isEmpty && extra1.2.isEmpty && extra2.2.isEmpty, "all fake requests are exact GET, no body, bounded timeout, Bearer only")
        return report
    }
    private static func postRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data("synthetic".utf8); return request
    }
}

private actor CatalogFakeProbe {
    private var reads = 0
    private var requests = 0
    private var failures: [String] = []
    private(set) var current = true
    var requestCount: Int { requests }
    var totals: (Int, Int, [String]) { (reads, requests, failures) }
    func invalidate() { current = false }
    func recordReadAttempt() { reads += 1 }
    func readFakeKey() -> Data { reads += 1; return Data("sk-synthetic-catalog-placeholder".utf8) }
    func record(_ request: URLRequest, expectedURL: URL) {
        requests += 1
        if request.url != expectedURL || request.httpMethod != "GET" || request.httpBody != nil || request.httpBodyStream != nil
            || request.value(forHTTPHeaderField: "Authorization") != "Bearer sk-synthetic-catalog-placeholder"
            || request.timeoutInterval <= 0 || request.timeoutInterval > 20 {
            failures.append("unsafe fake request")
        }
    }
}
private actor CatalogFakeGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { pending = $0; entered = true; started?.resume(); started = nil }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
