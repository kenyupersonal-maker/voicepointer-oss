import Foundation
import Combine
import VoicePointerCore

@MainActor
final class RecognitionMemoryRuntime: ObservableObject {
    static let shared = RecognitionMemoryRuntime()
    @Published private(set) var count = 0
    private var memory = RecognitionMemoryStore()
    private var enabled = true
    func setEnabled(_ value: Bool) {
        if enabled, !value { clear(reason: "toggleOff") }
        enabled = value
    }
    func refresh(now: Date = Date()) {
        let latestCount = memory.count(now: now)
        if count != latestCount { count = latestCount }
    }
    func record(_ record: DictationRecord, appKey: String, cloudSeen: Bool) {
        guard enabled else { return }
        let skip = memory.add(id: record.id, appKey: appKey, text: record.text, now: record.date,
            voiceNative: record.routeID != "doubao", delivered: true, cancelled: false, noise: false,
            cloudSeen: cloudSeen, source: record.routeID == "doubao" ? .doubao : .delivered)
        refresh()
        if let skip { RuntimeTrace.record("recognition memory skip reason=\(skip.rawValue)") }
        else { RuntimeTrace.record("recognition memory add source=\(record.routeID == "doubao" ? "doubao" : "voiceNative") chars=\(min(record.text.count, 400)) cloudSeen=\(cloudSeen ? 1 : 0) entries=\(count)") }
    }
    func replace(id: UUID, text: String) {
        memory.replace(id: id, text: text, now: Date()); refresh()
        RuntimeTrace.record("recognition memory replace chars=\(min(text.count, 400)) entries=\(count)")
    }
    func remove(id: UUID) {
        memory.remove(id: id); refresh()
        RuntimeTrace.record("recognition memory remove reason=undone entries=\(count)")
    }
    func clear(reason: String) {
        // Callers supply only the finite UI lifecycle reasons.
        let safe = ["button", "toggleOff", "dataRemoval"].contains(reason) ? reason : "button"
        let previous = count; memory.clear(); refresh()
        RuntimeTrace.record("recognition memory clear reason=\(safe) count=\(previous)")
    }
    func freeze(preferences: ProviderPreferences, appKey: String?) -> RecognitionContextPlan? {
        setEnabled(preferences.useRecentContextLocally)
        let mode = UserDefaults.standard.string(forKey: "recognitionContextMode") ?? "full"
        guard mode != "off" else { return nil }
        let key = appKey ?? ""
        let now = Date()
        let entries = memory.entries(appKey: key, now: now)
        refresh(now: now)
        return RecognitionContextPlanner.plan(selectedTerms: LexiconRuntime.shared.hotwords(
            applying: preferences.applyPersonalLexicon && preferences.useHotwordsLocally),
            memory: entries, appKey: key, now: now, destination: .local,
            options: .init(termsEnabled: preferences.applyPersonalLexicon && preferences.useHotwordsLocally,
                recentEnabled: preferences.useRecentContextLocally && mode != "terms"))
    }
}
