import AppKit
import Combine
import Foundation
import VoicePointerCore

private final class SyntheticSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TouchSample]
    private var mainRead = false
    private var reads = 0
    init(_ values: [TouchSample]) { self.values = values }
    func read() -> [TouchSample] {
        lock.withLock { reads += 1; mainRead = mainRead || Thread.isMainThread; return values }
    }
    func replace(_ next: [TouchSample]) { lock.withLock { values = next } }
    var readOnMain: Bool { lock.withLock { mainRead } }
    var readCount: Int { lock.withLock { reads } }
}

private actor SyntheticReadBarrier {
    private var reads = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func beforeRead() async {
        reads += 1
        guard reads == 1 else { return }
        await withCheckedContinuation { continuation in
            blocked = continuation; started?.resume(); started = nil
        }
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

@MainActor private final class SyntheticLiveValues {
    var value: MagicMouseLiveValues
    var reads = 0
    var allReadsOnMain = true
    init(_ value: MagicMouseLiveValues) { self.value = value }
    func read() -> MagicMouseLiveValues {
        reads += 1; allReadsOnMain = allReadsOnMain && Thread.isMainThread
        return value
    }
}

@MainActor private final class SyntheticSkin: HUDSkin {
    let view = NSView()
    var presents = 0
    var shutdowns = 0
    var running = false
    var holdRelease = false
    var pendingRelease: (@MainActor () -> Void)?
    func apply(_ environment: HUDEnvironment) {}
    func present(coreOnly: Bool) { presents += 1; running = true }
    func update(level: CGFloat) {}
    func update(pointer: HUDPointer) {}
    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void) {
        if holdRelease { pendingRelease = completion } else { completion() }
    }
    func completeRelease() { running = false; pendingRelease?(); pendingRelease = nil }
    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void) { completion() }
}

@main @MainActor enum F5SettingsCheck {
    private static var failures: [String] = []
    private static var assertions = 0
    private static func expect(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { failures.append(message) }
    }
    private static func onMainThread() -> Bool { Thread.isMainThread }
    private static func makeSamples() throws -> [TouchSample] {
        try (0..<500).map { i in
            let density = 0.6 + Double(i % 100) / 100
            let object: [String: Any] = [
                "t": 1000 + i, "b": "L", "dec": TouchSampleDecision.passed.rawValue, "n": 2, "hover": 0,
                "points": (0..<2).map { _ in ["stage": 4, "x": 0.4, "y": 0.6, "major": 0.2,
                                              "minor": 0.15, "size": 0.04, "density": density] },
                "holdMS": 125, "threshold": 1, "skewLimitMS": 80, "freshLimitMS": 350, "movementLimit": 0.08,
                "frameAgeMS": 10, "newestAgeMS": 10, "oldestAgeMS": 40, "movement": 0.01,
                "label": i % 2 == 0 ? "single" : "real",
            ]
            return try JSONDecoder().decode(TouchSample.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
    private static func source(_ live: SyntheticLiveValues, _ samples: SyntheticSamples) -> MagicMouseSettingsSource {
        .init(live: { live.read() }, samples: { samples.read() },
              mark: { value in MainActor.assumeIsolated { live.value.label = value } })
    }
    static func main() async throws {
        // A failed continuation assertion cannot leave the runner hanging indefinitely.
        let timeout = Task.detached {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            print("F5_SETTINGS_FAIL synthetic_check_timeout"); exit(3)
        }
        defer { timeout.cancel() }
        let samples = try makeSamples()
        await checkProcessor(samples)
        await checkRefresh(samples)
        await checkLifecycle(samples)
        await checkModelRelease(samples)
        checkActivityAndPreviews()
        for failure in failures { print("FAIL " + failure) }
        print("F5_SETTINGS_SYNTHETIC assertions=\(assertions) failures=\(failures.count) real_touch=0 enumeration=0 microphone=0 haptics=0 audio=0 network=0")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func checkProcessor(_ samples: [TouchSample]) async {
        let backing = SyntheticSamples(samples)
        let processor = MagicMouseSampleProcessor()
        var configuration = GestureConfiguration()
        let first = await processor.prepare(read: { backing.read() }, configuration: configuration)
        expect(first?.presentation.samples.count == 500 && first?.presentation.scatter.count == 500,
               "500 synthetic samples and their scatter points must be preserved")
        let expected = TouchSampleRecorder.compare(samples, configuration: configuration)
        expect(first?.presentation.rows.map(\.triggered) == expected.map(\.triggered), "cached ratios must match the production classifier")
        for _ in 0..<20 {
            let stable = await processor.prepare(read: { backing.read() }, configuration: configuration)
            expect(stable?.version == first?.version, "identical samples/configuration must keep the presentation version")
        }
        let initialCounts = (await processor.sampleComputations, await processor.comparisonComputations)
        expect(initialCounts == (1, 1),
               "unchanged polling must not recompute scatter or ratios")
        configuration.trackpadEnabled.toggle()
        _ = await processor.prepare(read: { backing.read() }, configuration: configuration)
        expect(await processor.comparisonComputations == 1, "unrelated gesture controls must not recompute mouse ratios")
        configuration.magicMouseMinDensity = 2
        let tuned = await processor.prepare(read: { backing.read() }, configuration: configuration)
        expect(tuned?.presentation.rows.allSatisfy { $0.triggered == 0 && $0.ratio == 0 } == true,
               "density tuning must still update predictions without a new sample")
        let tunedCounts = (await processor.sampleComputations, await processor.comparisonComputations)
        expect(tunedCounts == (1, 2),
               "tuning must recompute ratios but preserve the cached scatter")
        backing.replace(Array(samples.dropLast()))
        let changed = await processor.prepare(read: { backing.read() }, configuration: configuration)
        expect(changed?.presentation.samples.count == 499 && changed?.version != tuned?.version, "sample changes must replace the presentation")
        expect(!backing.readOnMain, "sample reads and processing must execute off the main thread")
        let beforeForced = await processor.comparisonComputations
        let forced = await processor.prepare(read: { backing.read() }, configuration: configuration, comparisonRequest: 1)
        expect(await processor.comparisonComputations == beforeForced + 1 && forced?.version == changed?.version,
               "explicit label revision recomputes once without republishing unchanged historical ratios")
        _ = await processor.prepare(read: { backing.read() }, configuration: configuration, comparisonRequest: 1)
        expect(await processor.comparisonComputations == beforeForced + 1,
               "an unchanged label request cannot recompute the same ratios again")
    }

    private static func checkRefresh(_ samples: [TouchSample]) async {
        let backing = SyntheticSamples(samples)
        let point = TouchSamplePoint(stage: 4, x: 0.4, y: 0.6, major: 0.2, minor: 0.15, size: 0.04, density: 1.2)
        let live = SyntheticLiveValues(.init(present: true,
            snapshot: .init(deviceToken: 1, points: [point], frameAgeSeconds: 0.01,
                            newestTouchAgeSeconds: 0.01, oldestTouchAgeSeconds: 0.03, maximumMovement: 0.01),
            decision: .init(reason: .passed, minDensity: 1.2)))
        let activity = SettingsLiveActivity()
        let processor = MagicMouseSampleProcessor()
        let state = MagicMouseSettingsState(fixture: nil, source: source(live, backing), activity: activity,
                                           processor: processor, visibility: { true }, automaticPolling: false)
        var publications = 0
        var allPublicationsOnMain = true
        let observer = state.objectWillChange.sink {
            MainActor.assumeIsolated { publications += 1; allPublicationsOnMain = allPublicationsOnMain && Thread.isMainThread }
        }
        defer { observer.cancel(); state.disappear() }
        state.setVisible(true)
        expect(state.refresh(at: 100), "the initial visible refresh must be admitted")
        await state.waitForSamplesForCheck()
        let start = DispatchTime.now().uptimeNanoseconds
        let refreshed = state.refresh(at: 100.1) // Includes assignment/publication of the prepared 500-sample presentation.
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let mainThread = onMainThread()
        expect(mainThread, "the measured synchronous refresh must run on the main thread")
        expect(refreshed && state.samples.count == 500, "the measured refresh must publish all 500 synthetic samples")
        expect(elapsed < 4, "one admitted main-thread 500-sample refresh must take less than 4 ms")
        print(String(format: "F5_MAIN_REFRESH samples=500 elapsed_ms=%.6f limit_ms=4.000000 main_thread=%@ scope=live_read_compare_publish_prepared_samples_schedule excludes=background_computation_swiftui_layout_metal", elapsed, mainThread ? "true" : "false"))
        await state.waitForSamplesForCheck()
        let before = publications
        _ = state.refresh(at: 100.2)
        await state.waitForSamplesForCheck()
        _ = state.refresh(at: 100.3)
        state.mark(.none)
        expect(publications == before, "unchanged live values/samples/label must cause zero @Published notifications")
        await state.waitForSamplesForCheck()
        live.value.snapshot?.frameAgeSeconds = 0.5
        _ = state.refresh(at: 100.4)
        expect(publications == before, "idle frame ages must not invalidate an unchanged displayed contour")
        var accepted: [Double] = []
        let readsBefore = live.reads
        for i in 0..<120 {
            let time = 101 + Double(i) / 120
            if state.refresh(at: time) { accepted.append(time) }
        }
        expect(accepted.count <= 15 && live.reads - readsBefore == accepted.count, "120 injected ticks/sec must read touch snapshots at most 15 Hz")
        expect(zip(accepted, accepted.dropFirst()).allSatisfy { $1 - $0 >= MagicMouseSettingsState.refreshInterval },
               "all admitted touch reads must be separated by at least 1/15 second")
        await state.waitForSamplesForCheck()
        let owner = UUID(), stoppedReads = live.reads, stoppedPublications = publications
        activity.setGestureActive(true, owner: owner)
        expect(!state.refresh(at: 103), "a gesture must pause the entire mouse group")
        activity.setHUDVisible(true, owner: owner)
        activity.setGestureActive(false, owner: owner)
        expect(!state.refresh(at: 104), "a visible HUD must keep the entire mouse group paused after release")
        expect(live.reads == stoppedReads && publications == stoppedPublications, "paused refresh must neither read live data nor publish")
        activity.setHUDVisible(false, owner: owner)
        expect(state.refresh(at: 105), "mouse refresh must resume once both gesture and HUD end")
        expect(live.allReadsOnMain && allPublicationsOnMain && !backing.readOnMain, "live reads/publication must stay on main, samples off main")
        await state.waitForSamplesForCheck()
        let beforeLabelComparison = await processor.comparisonComputations
        state.mark(.single)
        await state.waitForSamplesForCheck()
        expect(await processor.comparisonComputations == beforeLabelComparison + 1,
               "a real label switch schedules one background comparison even without a new sample")
        _ = state.refresh(at: 105.1)
        await state.waitForSamplesForCheck()
        state.mark(.single)
        expect(await processor.comparisonComputations == beforeLabelComparison + 1 && state.samples.map(\.label) == samples.map(\.label),
               "same label is inert and explicit marking never rewrites historical labels or denominators")
        state.disappear()
        state.attach(nil, visible: true)
        expect(!state.refresh(at: 106), "a late visibility notification cannot restart a disappeared page")
    }

    private static func checkLifecycle(_ samples: [TouchSample]) async {
        let backing = SyntheticSamples(samples)
        let live = SyntheticLiveValues(.init(present: true))
        let barrier = SyntheticReadBarrier()
        let processor = MagicMouseSampleProcessor(beforeRead: { await barrier.beforeRead() })
        let state = MagicMouseSettingsState(fixture: nil, source: source(live, backing), processor: processor,
                                           visibility: { true }, automaticPolling: false)
        state.setVisible(true)
        _ = state.refresh(at: 200)
        let abandoned = state.sampleTaskForCheck
        await barrier.waitUntilBlocked()
        state.disappear()
        await barrier.release()
        await abandoned?.value
        expect(state.samples.isEmpty, "a worker finishing after disappearance must not publish")
        backing.replace(Array(samples.prefix(3)))
        state.attach(nil, visible: true)
        state.appear(configuration: .init())
        _ = state.refresh(at: 201)
        await state.waitForSamplesForCheck()
        _ = state.refresh(at: 201.1)
        expect(state.samples.count == 3, "reappearance must publish the current samples, not the canceled result")
        await state.waitForSamplesForCheck()
        state.disappear()

        let epochBarrier = SyntheticReadBarrier()
        let epochState = MagicMouseSettingsState(fixture: nil, source: source(live, backing),
            processor: MagicMouseSampleProcessor(beforeRead: { await epochBarrier.beforeRead() }),
            visibility: { true }, automaticPolling: false)
        epochState.setVisible(true)
        _ = epochState.refresh(at: 300)
        let oldEpochTask = epochState.sampleTaskForCheck
        await epochBarrier.waitUntilBlocked()
        var configuration = GestureConfiguration(); configuration.magicMouseMinDensity = 2
        epochState.updateConfiguration(configuration)
        _ = epochState.refresh(at: 300.1)
        await epochState.waitForSamplesForCheck()
        await epochBarrier.release()
        await oldEpochTask?.value
        _ = epochState.refresh(at: 300.2)
        expect(epochState.samplePresentation.rows.allSatisfy { $0.triggered == 0 }, "a canceled earlier epoch cannot overwrite a newer threshold result")
        expect(epochState.samples.count == 3, "the newest epoch must retain the current sample array")
        epochState.disappear()

        let activity = SettingsLiveActivity(), owner = UUID()
        let hudBarrier = SyntheticReadBarrier()
        let hudState = MagicMouseSettingsState(fixture: nil, source: source(live, backing), activity: activity,
            processor: MagicMouseSampleProcessor(beforeRead: { await hudBarrier.beforeRead() }),
            visibility: { true }, automaticPolling: false)
        hudState.setVisible(true)
        _ = hudState.refresh(at: 400)
        let preHUDTask = hudState.sampleTaskForCheck
        await hudBarrier.waitUntilBlocked()
        activity.setHUDVisible(true, owner: owner)
        await hudBarrier.release()
        await preHUDTask?.value
        expect(hudState.samples.isEmpty && !hudState.refresh(at: 400.1), "a worker admitted before HUD display cannot publish while the HUD is visible")
        activity.setHUDVisible(false, owner: owner)
        _ = hudState.refresh(at: 401)
        await hudState.waitForSamplesForCheck()
        _ = hudState.refresh(at: 401.1)
        expect(hudState.samples.count == 3, "HUD hide must admit a fresh sample worker after the canceled one")
        hudState.disappear()

        // Cancel a just-scheduled poll before it can call even the injected loader.
        let loadCounter = SyntheticSamples([])
        let queuedState = MagicMouseSettingsState(fixture: nil, source: .init(live: { live.read() },
            samples: { backing.read() }, load: { _ = loadCounter.read() }), visibility: { true })
        let readsBefore = live.reads
        queuedState.setVisible(true)
        let queuedPoll = queuedState.refreshTaskForCheck
        queuedState.disappear()
        await queuedPoll?.value
        expect(live.reads == readsBefore && loadCounter.readCount == 0, "a canceled queued poll must not perform live reads or load samples")
    }

    private static func checkModelRelease(_ samples: [TouchSample]) async {
        let backing = SyntheticSamples(samples)
        let live = SyntheticLiveValues(.init(present: true))
        weak var released: MagicMouseSettingsState?
        var state: MagicMouseSettingsState? = MagicMouseSettingsState(fixture: nil, source: source(live, backing),
                                                                     visibility: { true })
        released = state
        state?.setVisible(true)
        _ = state?.refresh()
        await state?.waitForSamplesForCheck()
        state = nil
        for _ in 0..<20 { if released == nil { break }; await Task.yield() }
        expect(released == nil, "the refresh loop must not retain its state across sleeps")
    }

    private static func checkActivityAndPreviews() {
        let activity = SettingsLiveActivity(), first = UUID(), second = UUID()
        var events = 0
        let token = activity.observe { _ in events += 1 }
        activity.setHUDVisible(true, owner: first)
        activity.setHUDVisible(true, owner: first)
        activity.setHUDVisible(true, owner: second)
        activity.setHUDVisible(false, owner: first)
        expect(events == 1 && activity.snapshot.hudVisible, "unchanged or overlapping HUD owners must not resume previews or notify")
        activity.removeOwner(second)
        expect(events == 2 && !activity.snapshot.hudVisible, "the last HUD owner's removal must resume admission")
        activity.removeObserver(token)
        var skins: [SyntheticSkin] = []
        let preview = SkinPreviewView(paper: .lines, activity: activity,
            makeAssembly: { _ in
                let skin = SyntheticSkin(); skins.append(skin)
                return .init(skin: skin, radial: nil, syntheticMonitor: nil,
                             shutdown: { skin.shutdowns += 1; skin.running = false })
            },
            makeEnvironment: { .init(isDark: $0) }, log: { _ in })
        preview.configure(skin: .classic, dark: false)
        preview.setViewableForCheck(true)
        preview.setPreviewActive(true)
        let skin = skins[0]
        expect(preview.runningForCheck && skin.presents == 1, "an admitted preview must start its injected skin")
        activity.setHUDVisible(true, owner: first)
        expect(!preview.runningForCheck && skin.shutdowns == 1, "real HUD admission must synchronously stop the preview timer/assembly")
        activity.setHUDVisible(true, owner: first)
        expect(skin.shutdowns == 1, "unchanged activity must not repeat preview shutdown")
        activity.setHUDVisible(false, owner: first)
        expect(preview.runningForCheck && skins.count == 2 && skins[1].presents == 1,
               "HUD hide must resume a still-viewable requested preview with a fresh assembly")
        skins[1].holdRelease = true
        preview.releaseForCheck()
        let releasedSkin = skins[1]
        expect(releasedSkin.pendingRelease != nil, "delayed release fixture must arm the production preview callback")
        activity.setHUDVisible(true, owner: first)
        activity.setHUDVisible(false, owner: first)
        let resumedSkin = skins.last!
        expect(skins.count == 3 && resumedSkin !== releasedSkin && resumedSkin.running,
               "HUD interruption isolates the resumed skin from the old release instance")
        releasedSkin.completeRelease()
        expect(resumedSkin.running && preview.runningForCheck,
               "old delayed release cannot stop the resumed assembly")
        activity.setGestureActive(true, owner: first)
        expect(preview.runningForCheck && activity.snapshot.pausesMouseRefresh, "gesture admission pauses mouse refresh; HUD visibility controls preview rendering")
        activity.setHUDVisible(true, owner: first)
        preview.setViewableForCheck(false)
        activity.setHUDVisible(false, owner: first)
        expect(!preview.runningForCheck && skins.count == 3, "HUD hide must not resume a hidden preview")
        preview.setViewableForCheck(true)
        expect(preview.runningForCheck, "an admitted visible preview must recover")
        preview.shutdown()
        activity.setHUDVisible(true, owner: first)
        activity.removeOwner(first)
        expect(!preview.runningForCheck, "disposed preview must stay stopped after subsequent activity notifications")
        let trialActivity = SettingsLiveActivity(), trialOwner = UUID()
        var cancellations = 0
        var trialGate: SettingsHUDTrialGate? = .init(activity: trialActivity, cancel: { cancellations += 1 })
        expect(trialGate?.allowsStart == true, "screen trial can start before the HUD")
        trialActivity.setHUDVisible(true, owner: trialOwner)
        expect(trialGate?.allowsStart == false && cancellations == 1,
               "a real HUD admission synchronously cancels and blocks screen trials")
        trialActivity.setHUDVisible(false, owner: trialOwner)
        expect(trialGate?.allowsStart == true && cancellations == 1,
               "HUD hide permits a new explicit screen trial without automatically restarting one")
        trialGate = nil
        trialActivity.setHUDVisible(true, owner: trialOwner)
        expect(cancellations == 1, "disposed screen trial gate cannot react to later HUD activity")
    }
}
