import Foundation

public enum TeacherLearningPolicy {
    public static func tooDifferent(local: String, reference: String) -> Bool {
        let a = normalized(local), b = normalized(reference)
        return max(a.count, b.count) > 0 && EnhancementLearningPipeline.similarity(a, b) < 0.5
    }
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
    public static func isSensitive(_ text: String) -> Bool {
        RecognitionMemoryStore.isSensitive(text) || ["身份证", "护照", "银行卡", "住址", "我叫", "姓名", "联系人", "门牌", "隐私"]
            .contains { text.contains($0) } || text.contains("://") || text.contains("@")
    }
    public static func isProper(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) || CharacterSet.decimalDigits.contains($0) }
    }
    public static func contains(_ word: String, in text: String) -> Bool {
        let compact = normalized(word)
        guard !compact.isEmpty else { return false }
        let latin = compact.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let word = latin ? word.precomposedStringWithCompatibilityMapping.lowercased() : compact
        let text = latin ? text.precomposedStringWithCompatibilityMapping.lowercased() : normalized(text)
        guard let range = text.range(of: word) else { return false }
        if latin {
            let left = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let right = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            return !(left?.isASCII == true && (left?.isLetter == true || left?.isNumber == true))
                && !(right?.isASCII == true && (right?.isLetter == true || right?.isNumber == true))
        }
        return true
    }
}

/// One background RAM-only recheck. No recognizer, microphone, file or network is
/// owned here. The coordinator supplies the existing local pool and cancellation.
@MainActor public final class TeacherLearningRuntime {
    public typealias Recognizer = @Sendable (DoubaoLearningAudio, VoiceInputSnapshot, [String]) async throws -> String?
    public typealias Writer = @MainActor (EnhancementLearningPipeline.Promotion, EnhancementLearningPermit, UInt64) async -> Bool
    private var recognize: Recognizer?
    private var cancelRecognition: @Sendable () async -> Void = {}
    private let terms: @MainActor () -> [LexiconTerm]
    private let confirmed: @MainActor () -> [EnhancementLearningPipeline.Difference]
    private let ordinary: @MainActor (String) -> Bool
    private let persist: Writer
    private let trace: @MainActor (String) -> Void
    private let now: @MainActor () -> Date
    private let permit = EnhancementLearningPermit()
    private var epoch: UInt64 = 0
    private var online = false, doubao = false
    private var pending: EnhancementComparison?
    private var queue: [EnhancementComparison] = []
    private var deliveredIDs: Set<UUID> = []
    private var gestureActive = false
    private var activeTeacher = "cloud"
    private var task: Task<Void, Never>?, deadline: Task<Void, Never>?, drain: Task<Void, Never>?
    private var audio: DoubaoLearningAudio?
    private var rounds: [String: (ids: Set<UUID>, at: Date)] = [:]
    private var additions: [Date] = []
    private var pausedUntil: Date?
    public private(set) var promotions = 0
    public init(terms: @escaping @MainActor () -> [LexiconTerm],
                confirmed: @escaping @MainActor () -> [EnhancementLearningPipeline.Difference] = { [] },
                ordinary: @escaping @MainActor (String) -> Bool = { _ in false },
                now: @escaping @MainActor () -> Date = { Date() },
                trace: @escaping @MainActor (String) -> Void = { _ in }, persist: @escaping Writer) {
        self.terms=terms;self.confirmed=confirmed;self.ordinary=ordinary;self.now=now;self.trace=trace;self.persist=persist
    }
    public func configure(recognize: @escaping Recognizer, cancel: @escaping @Sendable () async -> Void) {
        cancelWork();self.recognize=recognize;cancelRecognition=cancel
    }
    public func authorize(online: Bool, doubao: Bool) {
        guard self.online != online || self.doubao != doubao else { return }
        cancelWork();self.online=online;self.doubao=doubao
    }
    public func cancelWork() {
        epoch=permit.update(enabled: false)
        let hadWork = pending != nil || task != nil || !queue.isEmpty
        queue.forEach { $0.audio?.clear() }; queue.removeAll(); deliveredIDs.removeAll()
        pending?.audio?.clear();pending=nil;audio?.clear();audio=nil
        task?.cancel();task=nil;deadline?.cancel();deadline=nil
        let prior=drain, cancel=cancelRecognition
        drain=Task { await prior?.value;await cancel() }
        if hadWork { trace("learn teacher=\(activeTeacher) decision=cancelled") }
    }
    public func waitForCancellation() async { await drain?.value;drain=nil }
    /// Foreground speech takes the pool immediately. The original RAM capture stays queued; each decoder
    /// consumes an independent fork, so cancellation never empties the next attempt's source.
    public func pause() {
        gestureActive = true
        epoch = permit.update(enabled: false)
        if let pending { queue.insert(pending, at: 0) }
        pending = nil; audio = nil
        task?.cancel(); task = nil
        let prior = drain, cancel = cancelRecognition
        drain = Task { await prior?.value; await cancel() }
        boundQueue(); scheduleExpiry()
    }
    public func resume() { gestureActive = false; startNext() }
    private func boundQueue() {
        while queue.count + (pending == nil ? 0 : 1) > 3 {
            let old = queue.removeFirst(); old.audio?.clear(); deliveredIDs.remove(old.roundID)
            trace("learn teacher=\(old.source == .doubao ? "doubao" : "cloud") decision=expired")
        }
    }
    private func expire() {
        queue.removeAll { input in
            guard (input.audio?.ageSeconds ?? 60) >= 60 else { return false }
            input.audio?.clear(); deliveredIDs.remove(input.roundID)
            trace("learn teacher=\(input.source == .doubao ? "doubao" : "cloud") decision=expired")
            return true
        }
        if let pending, (pending.audio?.ageSeconds ?? 60) >= 60 {
            trace("learn teacher=\(activeTeacher) decision=expired")
            let keptQueue = queue, keptIDs = deliveredIDs
            queue = []; deliveredIDs = []
            cancelWork()
            queue = keptQueue; deliveredIDs = keptIDs
        }
    }
    private func scheduleExpiry() {
        deadline?.cancel(); deadline = nil
        let ages = queue.compactMap { $0.audio?.ageSeconds } + [pending?.audio?.ageSeconds].compactMap { $0 }
        guard let oldest = ages.max() else { return }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, 60 - oldest)))
            guard !Task.isCancelled, let self else { return }
            self.expire(); self.startNext(); self.scheduleExpiry()
        }
    }
    private func startNext() {
        expire()
        guard !gestureActive, task == nil, pending == nil,
              let index = queue.firstIndex(where: { deliveredIDs.contains($0.roundID) }) else { scheduleExpiry(); return }
        pending = queue.remove(at: index); audio = pending?.audio
        epoch = permit.update(enabled: true)
        if let roundID = pending?.roundID { startDelivered(roundID: roundID) }
        scheduleExpiry()
    }
    public func receive(_ input: EnhancementComparison) {
        guard input.source == .doubao ? doubao : online else {
            input.audio?.clear();trace("learn teacher=\(input.source == .doubao ? "doubao" : "cloud") decision=unauthorized");return
        }
        activeTeacher = input.source == .doubao ? "doubao" : "cloud"
        if max(input.localText.count,input.referenceText.count)<=1500 {
            let a=TeacherLearningPolicy.normalized(input.localText),b=TeacherLearningPolicy.normalized(input.referenceText)
            let distance=Int((1-EnhancementLearningPipeline.similarity(a,b))*Double(max(a.count,b.count))+0.5)
            trace("learn comparison exact=\(input.localText == input.referenceText ? 1 : 0) distance=\(distance) characters=\(max(a.count,b.count))")
        }
        guard input.localText.count <= 1500, input.referenceText.count <= 1500,
              !TeacherLearningPolicy.isSensitive(input.localText), !TeacherLearningPolicy.isSensitive(input.referenceText),
              let capture=input.audio, capture.retainedBufferCount > 0, input.snapshot != nil else {
            input.audio?.clear();trace("learn teacher=\(input.source == .doubao ? "doubao" : "cloud") decision=filtered");return
        }
        if RecognitionHotwords.isEcho(text: input.localText, words: input.snapshot?.localHotwords ?? [], durationSeconds: capture.durationSeconds) {
            capture.clear(); trace("learn teacher=\(activeTeacher) decision=echo"); return
        }
        if TeacherLearningPolicy.tooDifferent(local: input.localText, reference: input.referenceText) {
            capture.clear(); trace("learn teacher=\(activeTeacher) decision=tooDifferent"); return
        }
        queue.append(input); boundQueue(); scheduleExpiry(); startNext()
    }
    public func delivered(roundID: UUID) {
        // An upload-only teacher can arrive after delivery. Keep bounded RAM-only receipts for that case.
        if deliveredIDs.count >= 64, !deliveredIDs.contains(roundID),
           let old = deliveredIDs.first(where: { id in id != pending?.roundID && !queue.contains(where: { $0.roundID == id }) }) {
            deliveredIDs.remove(old)
        }
        deliveredIDs.insert(roundID)
        guard pending?.roundID == roundID || queue.contains(where: { $0.roundID == roundID }) else { return }
        startNext()
    }
    private func startDelivered(roundID: UUID) {
        guard let input=pending,input.roundID==roundID,let snapshot=input.snapshot,
              let capture=audio, let recognize else {
            trace("learn teacher=\(activeTeacher) decision=notPending");return
        }
        let generation=epoch, teacher=input.source == .doubao ? "doubao" : "cloud"
        let a=TeacherLearningPolicy.normalized(input.localText),b=TeacherLearningPolicy.normalized(input.referenceText)
        guard !a.isEmpty,!b.isEmpty,a != b else {
            capture.clear();audio=nil;pending=nil;deliveredIDs.remove(roundID);startNext()
            trace("learn teacher=\(teacher) decision=unchanged");return
        }
        let differences=TeacherDifferences.split(local: input.localText, teacher: input.referenceText,
            rejected: { trace("learn teacher=\(teacher) decision=\($0.rawValue)") }).filter { d in
            guard !ordinary(d.canonical) else { trace("learn teacher=\(teacher) decision=commonWord"); return false }
            guard !TeacherLearningPolicy.isSensitive(d.canonical), !TeacherLearningPolicy.isSensitive(d.variant),
                  !EnhancementLearningPipeline.conflicts(d,terms:terms(),confirmed:confirmed()) else {
                trace("learn teacher=\(teacher) decision=filtered"); return false
            }
            return true
        }
        guard !differences.isEmpty else { capture.clear();audio=nil;pending=nil;deliveredIDs.remove(roundID);trace("learn teacher=\(teacher) decision=filtered");startNext();return }
        if let until=pausedUntil,now()<until {
            capture.clear();audio=nil;pending=nil;deliveredIDs.remove(roundID);trace("learn teacher=\(teacher) decision=cap");startNext();return
        }
        task=Task(priority:.utility) { [weak self] in
            guard let self else { capture.clear();return }
            let attempt = capture.fork()
            defer {
                attempt.clear()
                if self.epoch==generation {
                    capture.clear(); self.audio=nil;self.pending=nil;self.task=nil
                    self.deliveredIDs.remove(roundID); self.startNext()
                }
            }
            await self.drain?.value
            guard self.permit.allows(generation),!Task.isCancelled else { self.trace("learn teacher=\(teacher) decision=cancelled");return }
            let started=DispatchTime.now().uptimeNanoseconds
            var text: String?
            do { text=try await recognize(attempt,snapshot,differences.map(\.canonical)) } catch { text=nil }
            guard !Task.isCancelled,self.permit.allows(generation),capture.ageSeconds<60 else { self.trace("learn teacher=\(teacher) decision=cancelled");return }
            let ms=(DispatchTime.now().uptimeNanoseconds-started)/1_000_000
            let matched=text.map { output in differences.contains { TeacherLearningPolicy.contains($0.canonical,in:output) } } ?? false
            self.trace("learn recheck ms=\(ms) result=\(text == nil ? "skipped" : matched ? "matched" : "notMatched")")
            for difference in differences {
                guard !Task.isCancelled,self.permit.allows(generation) else { self.trace("learn teacher=\(teacher) decision=cancelled");return }
                let key=LexiconText.foldKey(difference.variant)+"\u{1F}"+difference.canonical
                let time=self.now()
                self.rounds=self.rounds.filter { time.timeIntervalSince($0.value.at)>=0 && time.timeIntervalSince($0.value.at)<3600 }
                var seen=self.rounds[key] ?? (ids:Set<UUID>(),at:time)
                guard seen.ids.insert(input.roundID).inserted else { self.trace("learn teacher=\(teacher) decision=duplicate");continue }
                seen.at=time;self.rounds[key]=seen
                let verified=text.map { TeacherLearningPolicy.contains(difference.canonical,in:$0) } ?? false
                guard verified || (seen.ids.count>=2 && TeacherLearningPolicy.isProper(difference.canonical)) else {
                    self.trace("learn teacher=\(teacher) decision=candidate");continue
                }
                guard !EnhancementLearningPipeline.conflicts(difference,terms:self.terms(),confirmed:self.confirmed()) else {
                    self.trace("learn teacher=\(teacher) decision=duplicate");continue
                }
                self.additions.removeAll { time.timeIntervalSince($0)<0 || time.timeIntervalSince($0)>=3600 }
                if let until=self.pausedUntil,time<until { self.trace("learn teacher=\(teacher) decision=cap");break }
                let common=self.ordinary(difference.variant)
                let promotion=EnhancementLearningPipeline.Promotion(difference:difference,sightings:seen.ids.count,verified:verified,hotwordOnly:common,rechecked:true)
                if await self.persist(promotion,self.permit,generation),self.permit.allows(generation) {
                    self.promotions+=1;self.additions.append(time);self.rounds[key]=nil
                    self.trace("learn teacher=\(teacher) decision=\(common ? "commonWord" : verified ? "verified" : "candidate")")
                    self.trace("learn added verified=\(verified ? 1 : 0) count=1")
                    self.trace("learn saved confidence=\(verified ? "verified" : "candidate") kind=\(common ? "hotwordOnly" : "correction")")
                    if self.additions.count>30 { self.pausedUntil=time.addingTimeInterval(3600);self.trace("learn teacher=\(teacher) decision=cap") }
                } else { self.trace("learn teacher=\(teacher) decision=notSaved") }
            }
        }
    }
    public func waitForWork() async { await task?.value }
}
