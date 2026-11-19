import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

enum TouchSampleRecorderChecks {
    static func runAll() async -> [String] {
        var failures: [String] = []
        var cases = 0
        func expect(_ value: Bool, _ message: String) { cases += 1; if !value { failures.append(message) } }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".cache/t145-synthetic-\(UUID().uuidString)")
        let trashRoot = root.appendingPathComponent("Trash")
        let trash: @Sendable (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trashRoot.appendingPathComponent(UUID().uuidString))
        }
        let recorder = TouchSampleRecorder(directory: root.appendingPathComponent("Cache"), trash: trash)
        let c = GestureConfiguration(magicMouseMinDensity: 1, magicMouseMaxLandingSkewMilliseconds: 150,
                                     magicMouseFastLandingMilliseconds: 150, magicMouseSlowMinDensity: 1)
        // Real C gate with injected states only. Snapshot density deliberately
        // differs from tracked-contact density; mutations after evaluation must
        // not leak into the durable down row.
        let driver = MultitouchDriver()
        guard driver.resetTestTouchState() else {
            return ["M3 injected gate refuses a loaded real framework"]
        }
        let exact = TouchSampleRecorder(directory: root.appendingPathComponent("ExactGate"), trash: trash)
        exact.label = .real
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01,
                                   newestTouchAgeSeconds: 0.02, oldestTouchAgeSeconds: 0.05, minDensity: 0.22)
        expect(driver.setTestMinDensity(1.25), "injected tracked density updated without snapshot mutation")
        let accepted = driver.consumeEligibleGesture(configuration: c)
        guard let frame = driver.takeLatestMouseDecision(), let accepted else {
            return failures + ["M3 accepted gate fixture"]
        }
        expect(frame.decision.reason == .passed && frame.decision.minDensity == 1.25, "actual accepted gate minimum")
        expect(abs(frame.snapshot.minDensity - 0.22) < 0.0001, "snapshot density differs from gate fixture")
        expect(frame.decision.oldestAgeSeconds == accepted.oldestTouchAgeSeconds &&
               frame.snapshot.oldestTouchAgeSeconds == accepted.oldestTouchAgeSeconds &&
               frame.decision.skewSeconds == accepted.oldestTouchAgeSeconds - accepted.newestTouchAgeSeconds,
               "accepted match, ages, skew and snapshot share evaluation timestamp")
        expect(frame.decision.retriedWithoutLift == false, "M2 absent means actual retry flag false")
        expect(driver.takeLatestMouseDecision() == nil, "frozen decision consumed once")
        expect(driver.setTestMinDensity(0.1), "later gate mutation")
        exact.updateDecision(.init(reason: .density, minDensity: 0.1), snapshot: driver.touchSnapshot(deviceIndex: 0))
        exact.recordDown(button: .left, frame: frame, configuration: c, wallTime: 10, monotonicTime: 1)
        exact.recordUp(button: .left, monotonicTime: 1.125)
        exact.flushForTesting()
        if let row = exact.recentSamples.first {
            expect(row.gateMinDensity == 1.25 && abs(row.minDensity - 0.22) < 0.0001 && row.dec == .passed,
                   "persisted gate minimum comes from frozen decision")
            expect(row.oldestAgeMS == accepted.oldestTouchAgeSeconds * 1000 &&
                   row.skewMS == frame.decision.skewSeconds.map { $0 * 1000 } && row.retriedWithoutLift == false,
                   "durable age skew retry are exact evaluation values")
            expect(row.wouldTrigger(configuration: c), "recalculation uses measured gate density")
        } else { failures.append("exact accepted row persisted") }
        for (newest, oldest, density, reason) in [
            (0.02, 0.34, Float(1.5), TouchSampleDecision.landingSkew),
            (2.1, 2.12, Float(1.5), TouchSampleDecision.freshWindow),
            (0.02, 0.05, Float(0.75), TouchSampleDecision.density)
        ] {
            expect(driver.resetTestTouchState(), "reset rejected gate fixture")
            driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01,
                                       newestTouchAgeSeconds: newest, oldestTouchAgeSeconds: oldest, minDensity: 0.22)
            expect(driver.setTestMinDensity(density), "rejected gate tracked density mutation")
            expect(driver.consumeEligibleGesture(configuration: c) == nil, "expected gate rejection")
            guard let failed = driver.takeLatestMouseDecision() else { failures.append("failed decision missing"); continue }
            expect(failed.decision.reason == reason && failed.decision.minDensity == density, "failed reason and actual gate density")
            expect(failed.decision.oldestAgeSeconds == failed.snapshot.oldestTouchAgeSeconds &&
                   failed.decision.skewSeconds == failed.snapshot.oldestTouchAgeSeconds - failed.snapshot.newestTouchAgeSeconds,
                   "failed age and skew share locked snapshot timestamp")
            exact.recordDown(button: .right, frame: failed, configuration: c, wallTime: oldest + 100, monotonicTime: 2)
            exact.recordUp(button: .right, monotonicTime: 2.1)
            exact.flushForTesting()
            expect(exact.recentSamples.last?.oldestAgeMS == failed.snapshot.oldestTouchAgeSeconds * 1000 &&
                   exact.recentSamples.last?.skewMS == failed.decision.skewSeconds.map { $0 * 1000 } &&
                   exact.recentSamples.last?.gateMinDensity == density,
                   "failed row preserves locked age skew density")
        }
        expect(driver.resetTestTouchState(), "reset production helper fixture")
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01, minDensity: 0.22)
        expect(driver.setTestMinDensity(1.4), "production helper tracked minimum")
        expect(driver.consumeEligibleGesture(configuration: c) != nil, "production helper accepted")
        expect(driver.setTestMinDensity(0.2), "mutate before production down helper")
        // Both production monitor flavors call this exact helper, with an
        // explicit recorder; this fixture never initializes the singleton.
        driver.recordLatestMouseDown(button: .left, configuration: c, recorder: exact)
        driver.recordLatestMouseDown(button: .left, configuration: c, recorder: exact)
        exact.flushForTesting()
        expect(exact.recentSamples.count == 5 && exact.recentSamples.last?.gateMinDensity == 1.4 &&
               exact.recentSamples.last?.dec == .passed, "production helper consumes one original evaluation")
        expect(driver.resetTestTouchState(), "reset no-device fixture")
        expect(driver.consumeEligibleGesture(configuration: c) == nil && driver.takeLatestMouseDecision() == nil,
               "no mouse cannot reuse prior diagnostic")
        if let data = try? Data(contentsOf: exact.fileURL) {
            let keys: Set<String> = ["t","b","dec","n","hover","points","holdMS","threshold","skewLimitMS","freshLimitMS","movementLimit","frameAgeMS","newestAgeMS","oldestAgeMS","movement","label","gateMinDensity","skewMS","retriedWithoutLift","edgeCount"]
            for line in data.split(separator: 10) {
                let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
                expect(json.map { Set($0.keys) == keys } ?? false, "new row exact numeric enum whitelist")
                expect(json?["retriedWithoutLift"] as? Bool == false, "retry field explicit false")
                expect((json?["points"] as? [[String: Any]])?.count == 2, "exact row points bounded")
            }
        } else { failures.append("exact JSON fixture read") }
        if let first = exact.recentSamples.first, let data = try? JSONEncoder().encode(first),
           var oldJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["gateMinDensity", "skewMS", "retriedWithoutLift"] { oldJSON.removeValue(forKey: key) }
            let oldData = try? JSONSerialization.data(withJSONObject: oldJSON)
            let oldRow = oldData.flatMap { try? JSONDecoder().decode(TouchSample.self, from: $0) }
            expect(oldRow?.gateMinDensity == nil && oldRow?.skewMS == nil && oldRow?.retriedWithoutLift == nil && oldRow != nil,
                   "old Codable rows have unmeasured optional gate fields")
            expect(oldRow?.oldestAgeMS == first.oldestAgeMS, "old age field unchanged on decode")
            expect((try? JSONDecoder().decode(TouchSample.self, from: data)) == first, "new exact row Codable roundtrip")
        } else { failures.append("old row fixture encode") }
        let countBeforeInvalid = exact.recentSamples.count
        for invalid in [Double.nan, .infinity, .greatestFiniteMagnitude] {
            let bad = TouchSampleDecisionFrame(decision: .init(reason: .passed, minDensity: 1.2,
                skewSeconds: invalid, oldestAgeSeconds: 0.04, retriedWithoutLift: false), snapshot: frame.snapshot)
            exact.recordDown(button: .left, frame: bad, configuration: c)
        }
        exact.recordDown(button: .left, frame: frame, configuration: c, wallTime: .nan)
        exact.flushForTesting()
        expect(exact.recentSamples.count == countBeforeInvalid, "nonfinite and overflow gate values rejected")
        let boundedExact = TouchSampleRecorder(directory: root.appendingPathComponent("BoundedExact"), trash: trash)
        boundedExact.label = .real
        var sixPoints = frame.snapshot
        sixPoints.points = Array(repeating: frame.snapshot.points[0], count: 6)
        sixPoints.oldestTouchAgeSeconds = 99
        boundedExact.recordDown(button: .left, frame: .init(decision: frame.decision, snapshot: sixPoints), configuration: c)
        boundedExact.flushForTesting()
        expect(boundedExact.recentSamples.first?.points.count == 6 && boundedExact.recentSamples.first?.n == 6,
               "sensor log retains all bounded raw points without changing contact count")
        expect(boundedExact.recentSamples.first?.oldestAgeMS == frame.decision.oldestAgeSeconds.map { $0 * 1000 },
               "oldestAgeMS uses supplied gate age when surface age differs")
        expect(recorder.label == .none, "mark starts none")
        recorder.label = .single
        func snapshot(_ density: Float, oldest: Double = 0.04, movement: Float = 0) -> TouchSurfaceSnapshot {
            .init(deviceToken: 1, points: (0..<2).map { _ in .init(stage: 4, x: 0.4, y: 0.6, major: 0.12, minor: 0.06, size: 0.02, density: density) },
                frameAgeSeconds: 0.01, newestTouchAgeSeconds: 0.01, oldestTouchAgeSeconds: oldest, maximumMovement: movement)
        }
        recorder.updateDecision(.init(reason: .density, minDensity: 0.9), snapshot: snapshot(0.9))
        for i in 0..<10 {
            recorder.recordDown(button: i % 2 == 0 ? .left : .right, snapshot: snapshot(i < 4 ? 1.2 : 0.9), configuration: c, monotonicTime: Double(i))
            recorder.recordUp(button: i % 2 == 0 ? .left : .right, monotonicTime: Double(i) + 0.125)
        }
        recorder.flushForTesting()
        expect(recorder.recentSamples.count == 10, "ten paired samples")
        expect(recorder.recentSamples.allSatisfy { abs($0.holdMS - 125) < 0.01 }, "down/up duration pairing")
        let comparisons = TouchSampleRecorder.compare(recorder.recentSamples, configuration: c)
        expect(comparisons[0].triggered == 4 && comparisons[0].ratio == 0.4, "current threshold ratio synthetic")
        var disabledGate = c; disabledGate.magicMouseMinDensity = 0
        expect(TouchSampleRecorder.compare(recorder.recentSamples, configuration: disabledGate)[0].triggered == 10, "zero density threshold passes all valid fixtures")
        var history = Array(repeating: recorder.recentSamples[0], count: 510)
        for i in 0..<10 { history[i].label = .real }
        let bounded = TouchSampleRecorder.compare(history, configuration: disabledGate)
        expect(bounded[0].count == 500 && bounded[1].count == 0, "combined recent labeled window is capped at five hundred")
        history.append(contentsOf: history.suffix(20).map { sample in var value = sample; value.label = .none; return value })
        expect(TouchSampleRecorder.compare(history, configuration: disabledGate)[0].count == 500, "unlabeled samples do not enter comparison denominator")
        var tightened = disabledGate; tightened.magicMouseMaxLandingSkewMilliseconds = 20
        expect(TouchSampleRecorder.compare(recorder.recentSamples, configuration: tightened)[0].triggered == 0, "landing slider affects recalculation")
        tightened = disabledGate; tightened.magicMouseFreshChordWindowMilliseconds = 20
        expect(TouchSampleRecorder.compare(recorder.recentSamples, configuration: tightened)[0].triggered == 0, "fresh slider affects recalculation")
        var moved = recorder.recentSamples
        for i in moved.indices { moved[i].movement = 0.09 }
        expect(TouchSampleRecorder.compare(moved, configuration: disabledGate)[0].triggered == 0, "movement slider excludes moved contacts")
        var wideMovement = disabledGate; wideMovement.maximumTouchMovement = 0.1
        expect(TouchSampleRecorder.compare(moved, configuration: wideMovement)[0].triggered == 10, "movement slider enables moved contacts")
        if let data = try? Data(contentsOf: recorder.fileURL) {
            let keys: Set<String> = ["t","b","dec","n","hover","points","holdMS","threshold","skewLimitMS","freshLimitMS","movementLimit","frameAgeMS","newestAgeMS","oldestAgeMS","movement","label","edgeCount"]
            for line in data.split(separator: 10) {
                let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
                expect(json.map { Set($0.keys) == keys } ?? false, "sample keys exact whitelist")
                let points = json?["points"] as? [[String: Any]] ?? []
                expect(points.allSatisfy { Set($0.keys) == Set(["stage","x","y","major","minor","size","density","edge"]) }, "touch keys sensor-only")
            }
        } else { failures.append("synthetic file write") }
        let reboot = TouchSampleRecorder(directory: root.appendingPathComponent("Cache"), trash: trash)
        await reboot.refreshRecentSamples()
        expect(reboot.label == .none && reboot.recentSamples.count == 10, "restart clears mark and reloads recent samples")
        recorder.recordDown(button: .left, snapshot: snapshot(1.3), configuration: c)
        recorder.flushForTesting()
        let before = (try? Data(contentsOf: recorder.fileURL)) ?? Data()
        var off = c; off.touchSampleRecordingEnabled = false; recorder.configure(off)
        recorder.recordUp(button: .left)
        recorder.flushForTesting()
        expect((try? Data(contentsOf: recorder.fileURL)) == before, "disable prevents late up write for already durable down")
        recorder.recordDown(button: .left, snapshot: snapshot(1.3), configuration: off)
        recorder.recordUp(button: .left); recorder.flushForTesting()
        expect((try? Data(contentsOf: recorder.fileURL)) == before, "disabled no additional writes")
        recorder.configure(c)
        recorder.recordDown(button: .left, snapshot: snapshot(1.3), configuration: c)
        recorder.flushForTesting()
        let beforeRemoval = try? Data(contentsOf: recorder.fileURL)
        await recorder.beginDataRemoval()
        recorder.endDataRemoval(permanently: true)
        recorder.recordUp(button: .left); recorder.flushForTesting()
        expect((try? Data(contentsOf: recorder.fileURL)) == beforeRemoval, "removal barrier invalidates queued pairs")
        recorder.endDataRemoval()
        expect(await recorder.clear() == .idle, "clear synthetic Trash succeeds")
        recorder.recordUp(button: .left); recorder.flushForTesting()
        expect(!FileManager.default.fileExists(atPath: recorder.fileURL.path), "old up cannot recreate cleared log")
        expect(!((try? FileManager.default.contentsOfDirectory(atPath: trashRoot.path)) ?? []).isEmpty, "clear moved to fake Trash")

        let rotated = TouchSampleRecorder(directory: root.appendingPathComponent("Rotation"), trash: trash)
        try? FileManager.default.createDirectory(at: rotated.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 32, count: 1_999_999).write(to: rotated.fileURL)
        for i in 0..<4 {
            rotated.recordDown(button: .left, snapshot: snapshot(1.2), configuration: c, monotonicTime: Double(i))
            rotated.recordUp(button: .left, monotonicTime: Double(i) + 0.1)
            if i % 100 == 0 { rotated.flushForTesting() }
        }
        rotated.flushForTesting()
        expect(FileManager.default.fileExists(atPath: rotated.rotatedURL.path), "rotation beyond two million bytes")
        expect(((try? rotated.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 2_000_000, "active file bounded")
        expect(((try? rotated.rotatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 2_000_000, "rotated file bounded")

        let small = TouchSampleRecorder(directory: root.appendingPathComponent("SmallRotation"), rotateBytes: 1024, trash: trash)
        let trashBefore = ((try? FileManager.default.contentsOfDirectory(atPath: trashRoot.path)) ?? []).count
        for i in 0..<12 {
            small.recordDown(button: .left, frame: frame, configuration: c, wallTime: Double(2000 + i), monotonicTime: Double(i))
            small.recordUp(button: .left, monotonicTime: Double(i) + 0.1)
        }
        small.flushForTesting()
        expect(small.storageState == .idle, "bounded repeated rotation succeeds")
        expect(((try? FileManager.default.contentsOfDirectory(atPath: trashRoot.path)) ?? []).count > trashBefore, "superseded rotation goes to fake Trash")
        expect(((try? FileManager.default.contentsOfDirectory(atPath: small.fileURL.deletingLastPathComponent().path)) ?? []).count == 2, "only two active sample files remain")
        for url in [small.fileURL, small.rotatedURL] {
            let data = (try? Data(contentsOf: url)) ?? Data()
            let rows = data.split(separator: 10).compactMap { try? JSONDecoder().decode(TouchSample.self, from: Data($0)) }
            expect(!rows.isEmpty && rows.allSatisfy { $0.gateMinDensity == 1.25 && $0.skewMS == frame.decision.skewSeconds.map { $0 * 1000 } &&
                $0.retriedWithoutLift == false && abs($0.holdMS - 100) < 0.01 }, "rotation and duration replacement preserve exact gate fields")
        }

        let protectedWrite = TouchSampleRecorder(directory: root.appendingPathComponent("AtomicFailure"), trash: trash)
        protectedWrite.recordDown(button: .left, snapshot: snapshot(1.2), configuration: c)
        protectedWrite.flushForTesting()
        let original = try? Data(contentsOf: protectedWrite.fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedWrite.fileURL.deletingLastPathComponent().path)
        protectedWrite.recordUp(button: .left); protectedWrite.flushForTesting()
        expect(protectedWrite.storageState == .failed && original != nil && (try? Data(contentsOf: protectedWrite.fileURL)) == original,
               "failed private atomic stage preserves original bytes")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedWrite.fileURL.deletingLastPathComponent().path)

        let blocked = TouchSampleRecorder(directory: root.appendingPathComponent("Blocked"), maximumQueuedOperations: 1, trash: trash)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { continuation in
            blocked.blockQueueForTesting { continuation.resume(); release.wait() }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { blocked.recordDown(button: .left, snapshot: snapshot(1.2), configuration: c) }
        expect(ProcessInfo.processInfo.systemUptime - start < 1 && blocked.droppedCount == 1000, "full queue drops without waiting")
        release.signal(); blocked.flushForTesting()

        let outside = root.appendingPathComponent("outside.jsonl")
        try? Data("unchanged".utf8).write(to: outside)
        let linkedDir = root.appendingPathComponent("Linked")
        try? FileManager.default.createDirectory(at: linkedDir, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: linkedDir.appendingPathComponent("touch-samples.jsonl"), withDestinationURL: outside)
        let linked = TouchSampleRecorder(directory: linkedDir, trash: trash)
        linked.recordDown(button: .left, snapshot: snapshot(1.2), configuration: c)
        linked.recordUp(button: .left); linked.flushForTesting()
        expect(linked.storageState == .failed && (try? Data(contentsOf: outside)) == Data("unchanged".utf8), "symlink path refuses read/write")
        print("event=t145_recorder,cases=\(cases),failures=\(failures.count),synthetic=1,real_cleanup=0")
        return failures
    }
}
