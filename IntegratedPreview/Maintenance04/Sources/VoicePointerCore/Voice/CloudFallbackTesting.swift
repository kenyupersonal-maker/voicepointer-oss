import Foundation

@_spi(Testing) @MainActor public enum CloudFallbackTesting {
    public static func run() async -> [String] {
        var failures: [String] = []
        for fails in [true, false] {
            let source = HybridTestingSource()
            _ = source.appendBuffer(frames: 64, sampleRate: 16_000)
            let hub = SharedCaptureHub(makeSource: { source })
            let primary = HybridTestingBranch(role: .cloud)
            primary.attach(capture: { hub.makeView(.cloud) }, permission: { true })
            primary.finishStyle = fails ? .failure("ALI_NETWORK_ERROR") : .final("fixture_cloud")
            let local = HybridTestingBranch(role: .local)
            local.attach(capture: { hub.makeView(.local, allowSealedSnapshot: true) }, permission: { true })
            local.finishStyle = .final("fixture_local")
            let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "aliyun", language: "zh")
            let snapshot = try! VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0)
            let backend = CloudOnlyFallbackBackend(hub: hub, primary: primary, local: local,
                localSnapshot: CloudDictationStart.localFallbackSnapshot(for: snapshot)!)
            var finalText: String?, failed = false
            do {
                try await backend.start(snapshot: snapshot) {
                    if $0.kind == .final { finalText = $0.text }
                    if $0.kind == .failed { failed = true }
                }
                primary.emitReady()
                await backend.finish()
                if source.startCount != 1 || source.stopCount != 1 || failed || !backend.isQuiescent {
                    failures.append("cloud fallback: single capture owner")
                }
                if fails {
                    if local.startCount != 1 || finalText != "fixture_local"
                        || local.finishSnapshotIdentities != primary.finishSnapshotIdentities {
                        failures.append("cloud fallback: sealed identical RAM replay")
                    }
                } else if local.startCount != 0 || finalText != "fixture_cloud" {
                    failures.append("cloud fallback: healthy cloud unchanged")
                }
            } catch { failures.append("cloud fallback: synthetic startup") }
            await backend.cancel()
        }
        return failures
    }
}
