import Foundation
import CoreFoundation

/// Network adapters. Creation is inert; only an explicit validate call can launch a worker.
public enum OnlineAPILiveValidation {
    /// Explicit model selection only. Metadata is checked again before the key enters a pipe.
    public static func checkModel(configuration: OnlineAPIConfiguration, credentials: CloudCredentialStore) async -> OnlineAPIProbeResult {
        do {
            _ = try configuration.validatedEndpoint()
            guard try await credentials.storedRevision(provider: configuration.credentialSlot) == configuration.credentialRevision else { return .failed(.connection(.noKey)) }
            try Task.checkCancellation()
            var bytes = try await credentials.readForPipe(provider: configuration.credentialSlot, expectedRevision: configuration.credentialRevision)
            defer { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll() }
            let draft = try OnlineAPIDraftKey(pipeBytes: bytes)
            defer { draft.clear() }
            return await service().checkSelectedModel(configuration: configuration, draft: draft)
        } catch is CancellationError { return .failed(.cancelled) }
        catch { return .failed(.connection(CloudConnectionCheck.classify(error))) }
    }
    public static func service() -> OnlineAPIValidationService {
        OnlineAPIValidationService { request, draft in
            do {
                var key = try draft.copyForPipe()
                defer { key.resetBytes(in: 0..<key.count); key.removeAll(keepingCapacity: false) }
                try Task.checkCancellation()
                switch request.kind {
                case .aliyunHandshake(let modelID):
                    guard request.provider.isAliyun else { return .failed(.connection(.unknown)) }
                    let handshake = try CloudConnectionCheck.aliyunHandshake(endpoint: request.endpoint.absoluteString, modelID: modelID)
                    try await handshake(key)
                    return .ready
                case .models:
                    guard !request.provider.isAliyun else { return .failed(.connection(.unknown)) }
                    let launcher = try modelsLauncher(provider: request.provider)
                    return await modelsProbe(provider: request.provider, key: key, launcher: launcher)
                }
            } catch is CancellationError { return .failed(.cancelled) }
            catch { return .failed(.connection(CloudConnectionCheck.classify(error))) }
        }
    }

    private static func modelsLauncher(provider: OnlineAPIProvider) throws -> URL {
        guard provider == .groq || provider == .openai || provider == .siliconflow, let resources = Bundle.main.resourceURL,
              let backend = IntegratedRuntimePaths.backendResources else { throw CloudConnectionCheck.HandshakeError.workerUnavailable }
        let resourcePrefix = resources.resolvingSymlinksInPath().path + "/"
        let physical = backend.resolvingSymlinksInPath()
        guard physical.path.hasPrefix(resourcePrefix) else { throw CloudConnectionCheck.HandshakeError.workerUnavailable }
        let prefix = physical.path + "/"
        let stem = provider == .groq ? "groq" : provider == .siliconflow ? "siliconflow" : "openai"
        let names = ["launch-\(stem)-models.sh", "\(stem)-models.sb", "online_models_worker.py"]
        for name in names {
            let url = physical.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(prefix) else { throw CloudConnectionCheck.HandshakeError.workerUnavailable }
        }
        return physical.appendingPathComponent(names[0])
    }

    private static func modelsProbe(provider: OnlineAPIProvider, key: Data, launcher: URL) async -> OnlineAPIProbeResult {
        let worker = StreamingLineWorker(command: ["/bin/bash", launcher.path])
        let session = UUID()
        return await withTaskCancellationHandler(operation: {
            let result: OnlineAPIProbeResult
            do {
                var frame = try OnlineAPIModelsWire.request(provider: provider, sessionID: session, key: key)
                defer { frame.resetBytes(in: 0..<frame.count); frame.removeAll(keepingCapacity: false) }
                let line = try await worker.launch(initialLine: frame)
                result = try OnlineAPIModelsWire.response(line, provider: provider, sessionID: session)
            } catch is CancellationError { result = .failed(.cancelled) }
            catch { result = .failed(.connection(CloudConnectionCheck.classify(error))) }
            await worker.shutdown()
            guard await worker.isQuiescent() else { return .failed(.connection(.notClosed)) }
            return result
        }, onCancel: { Task { await worker.shutdown() } })
    }
}

/// Strict, bounded protocol. Only known model IDs or finite error enums return to the host.
public enum OnlineAPIModelsWire {
    public static func request(provider: OnlineAPIProvider, sessionID: UUID, key: Data) throws -> Data {
        guard !provider.isAliyun, (16...4096).contains(key.count), key.allSatisfy({ (33...126).contains($0) }) else {
            throw StreamingWorkerError.invalid
        }
        let object: [String: Any] = ["v": 1, "type": "models", "provider": provider.rawValue,
                                  "session_id": sessionID.uuidString, "key": String(decoding: key, as: UTF8.self)]
        let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
        guard line.count <= 8193 else { throw StreamingWorkerError.invalid }
        return line
    }
    public static func response(_ data: Data, provider: OnlineAPIProvider, sessionID: UUID) throws -> OnlineAPIProbeResult {
        guard data.count <= 8192, !data.contains(10), !data.contains(13),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.intValue == 1,
              v.doubleValue == 1, obj["provider"] as? String == provider.rawValue,
              obj["session_id"] as? String == sessionID.uuidString,
              let kind = obj["kind"] as? String else { throw StreamingWorkerError.invalid }
        let base: Set<String> = ["v", "provider", "session_id", "kind"]
        if kind == "models" {
            guard Set(obj.keys) == base.union(["models"]), let ids = obj["models"] as? [String],
                  ids.count <= provider.modelIDs.count, Set(ids).count == ids.count,
                  ids.allSatisfy(provider.modelIDs.contains) else { throw StreamingWorkerError.invalid }
            return .models(provider.modelIDs.filter(Set(ids).contains))
        }
        guard kind == "failed", Set(obj.keys) == base.union(["code"]), let code = obj["code"] as? String else { throw StreamingWorkerError.invalid }
        switch code {
        case "rejectedKey": return .failed(.connection(.rejectedKey))
        case "noAccess": return .failed(.connection(.noAccess))
        case "insufficientQuota": return provider == .openai ? .failed(.insufficientQuota) : .failed(.connection(.unknown))
        case "rateLimited": return .failed(.connection(.rateLimited))
        case "serviceUnavailable": return .failed(.connection(.serviceUnavailable))
        case "network": return .failed(.connection(.network))
        case "timeout": return .failed(.connection(.timeout))
        case "unknown": return .failed(.connection(.unknown))
        default: throw StreamingWorkerError.invalid
        }
    }
}
