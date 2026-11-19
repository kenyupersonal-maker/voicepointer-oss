import Foundation
import VoicePointerCore

enum RecognitionMemoryChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("recognition-memory: " + label) } }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var store = RecognitionMemoryStore()
        @discardableResult func add(_ text: String, app: String = "test.editor", id: UUID = UUID(), offset: Double = 0,
                                   voice: Bool = true, delivered: Bool = true, cancel: Bool = false, noise: Bool = false, cloud: Bool = false) -> RecognitionMemoryStore.Skip? {
            store.add(id: id, appKey: app, text: text, now: now.addingTimeInterval(offset), voiceNative: voice,
                delivered: delivered, cancelled: cancel, noise: noise, cloudSeen: cloud)
        }
        expect(add("first") == nil, "confirmed delivery")
        let id = UUID()
        add("second", id: id, offset: 1, cloud: true); add("third", offset: 2); add("fourth", offset: 3)
        var values = store.entries(appKey: "test.editor", now: now.addingTimeInterval(4))
        expect(values.map(\.text) == ["second", "third", "fourth"], "newest three")
        expect(values[0].cloudSeen && values[0].source == .delivered, "frozen cloud evidence")
        expect(store.entries(appKey: "other", now: now.addingTimeInterval(4)).isEmpty, "app isolation")
        store.replace(id: id, text: "corrected", now: now.addingTimeInterval(5))
        values = store.entries(appKey: "test.editor", now: now.addingTimeInterval(5))
        expect(values[0].text == "corrected" && values[0].source == .userCorrected && values[0].createdAt == now.addingTimeInterval(1), "replace preserves age")
        store.observe(id: id, change: .cleared, now: now.addingTimeInterval(5))
        expect(store.count(now: now.addingTimeInterval(5)) == 3, "cleared keeps memory")
        store.observe(id: id, change: .undone, now: now.addingTimeInterval(5))
        expect(store.count(now: now.addingTimeInterval(5)) == 2, "undo removes")
        let long = UUID(); add(String(repeating: "👨‍👩‍👧‍👦", count: 401), id: long, offset: 6)
        expect(store.entries(appKey: "test.editor", now: now.addingTimeInterval(6)).last?.text.count == 400, "whole Character suffix")
        store.replace(id: long, text: "", now: now.addingTimeInterval(7))
        expect(store.count(now: now.addingTimeInterval(7)) == 2, "empty edit removes")
        for sensitive in ["1234567", "mail@example.com", "https://example.invalid/?token=value", "key = value", "secret=abc", "sk-demo", "AKIAEXAMPLE", String(repeating: "a", count: 32), "password", "passcode", "密码", "验证码"] {
            expect(add(sensitive, offset: 8) == .sensitive, "sensitive class rejected")
        }
        expect(add("release 123456", offset: 8) == nil, "six digit nonsensitive boundary")
        expect(add("A useful sentence.", offset: 8) == nil, "normal words")
        expect(add(String(repeating: "sentence ", count: 100) + " token=secret", offset: 8) == .sensitive, "filter before truncating")
        expect(add("hello", app: "com.1password.1password", offset: 8) == .denyApp, "password manager")
        expect(add("hello", app: "com.apple.Passwords", offset: 8) == .denyApp, "system passwords")
        expect(add("hello", app: "", offset: 8) == .empty, "empty app")
        expect(add("hello", offset: 8, voice: false) == .notDelivered, "Doubao excluded")
        expect(add("hello", offset: 8, delivered: false) == .notDelivered, "unconfirmed/failed excluded")
        expect(add("hello", offset: 8, cancel: true) == .notDelivered, "cancel excluded")
        expect(add("hello", offset: 8, noise: true) == .noise, "noise excluded")
        expect(add("\u{7}bad", offset: 8) == .empty, "control rejected")
        store.clear(); add("boundary")
        expect(store.count(now: now.addingTimeInterval(599.999)) == 1, "before expiry")
        expect(store.count(now: now.addingTimeInterval(600)) == 0, "exact expiry")
        add("future", offset: 10)
        expect(store.count(now: now) == 0, "future date discarded")
        for n in 0..<8 { add("app memory", app: "test.\(n)", offset: Double(n)) }
        _ = store.entries(appKey: "test.0", now: now.addingTimeInterval(8))
        add("ninth", app: "test.8", offset: 8)
        expect(store.entries(appKey: "test.1", now: now.addingTimeInterval(8)).isEmpty, "LRU eviction")
        expect(!store.entries(appKey: "test.0", now: now.addingTimeInterval(8)).isEmpty, "access refreshes LRU")
        store.clear(); let recentID = UUID()
        add("older text", id: recentID, cloud: true); add("newer 👨‍👩‍👧‍👦", offset: 1); add("newer 👨‍👩‍👧‍👦", offset: 2)
        let entries = store.entries(appKey: "test.editor", now: now.addingTimeInterval(3))
        func plan(_ terms: [String], bytes: Int = 600, cloud: Bool = false, recent: Bool = true, words: Bool = true, app: String = "test.editor") -> RecognitionContextPlan? {
            RecognitionContextPlanner.plan(selectedTerms: terms, memory: entries, appKey: app, now: now.addingTimeInterval(3),
                destination: cloud ? .cloud : .local, options: .init(termsEnabled: words, recentEnabled: recent, localBytes: bytes))
        }
        expect(plan(["Alpha", "alpha", "Beta"])?.terms == ["Alpha", "Beta"], "case insensitive terms")
        expect(plan(["Alpha"])?.recent == ["older text", "newer 👨‍👩‍👧‍👦"], "recent dedup and order")
        expect(plan(["Alpha"], cloud: true)?.recent == ["older text"], "cloudSeen only")
        expect(plan(["Alpha"], recent: false)?.localText == "Alpha", "recent off")
        expect(plan(["Alpha"], words: false)?.terms.isEmpty == true, "terms off")
        expect(plan([], app: "") == nil, "unknown app no recent")
        expect(plan([], bytes: 0) == nil, "empty budget")
        let small = plan(["Alpha"], bytes: 5)
        expect(small?.localText == "Alpha" && small?.recent.isEmpty == true, "terms priority")
        expect(plan([], bytes: 31)?.recent.last == "newer 👨‍👩‍👧‍👦", "no emoji split")
        expect((plan((0..<40).map { "term\($0)" })?.terms.count ?? 0) == 16, "term cap")
        let wide = plan((0..<40).map { "词词词词词\($0)" })
        expect((wide?.terms.joined(separator: ", ").utf8.count ?? 0) <= 240, "term byte cap")
        expect(plan(["bad\u{7}term", "ok"])?.terms == ["ok"], "term control rejected")
        expect(plan([String(repeating: "字", count: 65)], cloud: true)?.terms.isEmpty == true, "cloud term length")
        store.replace(id: recentID, text: "password hidden", now: now.addingTimeInterval(3))
        expect(store.entries(appKey: "test.editor", now: now.addingTimeInterval(3)).allSatisfy { $0.id != recentID }, "sensitive edit removes stale entry")
        store.clear()
        expect(store.count(now: now.addingTimeInterval(3)) == 0, "clear all")
        expect(store.add(id: UUID(), appKey: "test.doubao", text: "豆包落下的词", now: now,
            voiceNative: false, delivered: true, cancelled: false, noise: false, cloudSeen: false, source: .doubao) == nil,
            "confirmed Doubao span enters RAM memory")
        expect(store.add(id: UUID(), appKey: "test.doubao", text: "不确认的词", now: now,
            voiceNative: false, delivered: false, cancelled: false, noise: false, cloudSeen: false, source: .doubao) == .notDelivered,
            "unconfirmed Doubao span cannot enter memory")
        return failures
    }
}
