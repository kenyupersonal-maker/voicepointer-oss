import Foundation
import AVFoundation

@_spi(Testing) public enum TeacherLearningTesting {
    @MainActor public static func run() async -> [String] {
        var failures: [String]=[]
        func expect(_ value: Bool,_ label: String) { if !value { failures.append("teacher recheck: "+label) } }
        expect(!TeacherDifferences.split(local: "打开，错词。", teacher: "打开对词！").isEmpty
            && TeacherDifferences.split(local: "打开，对词。", teacher: "打开对词！").isEmpty,
            "teacher split ignores punctuation while retaining a word change")
        do {
            let selection=try VoiceInputSelection(mode:.voiceNative,routeID:"qwen06-rolling",language:"zh")
            func input(_ index: Int) throws -> EnhancementComparison {
                let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16_000,channels:1,interleaved:false)!
                let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:64)!
                buffer.frameLength=64
                for i in 0..<64 { buffer.floatChannelData![0][i]=0.2 }
                let snapshot=try VoiceInputSnapshot(sessionID:UUID(),selection:selection,lexiconRevision:0)
                return .init(roundID:snapshot.sessionID,localText:"请帮我打开今天设计评审的CloudWrong\(index)项目看看界面",referenceText:"请帮我打开今天设计评审的ProductTerm\(index)项目看看界面",
                    localAt:Date(),referenceAt:Date(),localConfidence:nil,source:.onlineAPI,
                    audio:DoubaoLearningAudio([try OwnedPCMBuffer(copying:buffer)]),snapshot:snapshot)
            }
            var saved: [EnhancementLearningPipeline.Promotion]=[]
            var logs: [String]=[]
            let good=TeacherLearningRuntime(terms:{ [] },trace:{ logs.append($0) },persist:{ p,permit,epoch in
                guard permit.allows(epoch) else { return false };saved.append(p);return true
            })
            good.configure(recognize:{ value,_,words in value.clear();return words.first.map { "please open " + $0 + " now" } },cancel:{})
            good.authorize(online:true,doubao:false)
            let positive=try input(0)
            good.receive(positive);good.delivered(roundID:positive.roundID);await good.waitForWork()
            expect(saved.count==1 && saved[0].verified && saved[0].sightings==1
                && saved[0].difference.canonical=="ProductTerm0" && saved[0].difference.variant=="CloudWrong0",
                "fake worker matched whole candidate promotes without confidence gate")
            let bad=TeacherLearningRuntime(terms:{ [] },persist:{ _,_,_ in failures.append("unexpected nonmatched promotion");return false })
            bad.configure(recognize:{ value,_,_ in value.clear();return "没有认出候选" },cancel:{})
            bad.authorize(online:true,doubao:false)
            let negative=try input(1)
            bad.receive(negative);bad.delivered(roundID:negative.roundID);await bad.waitForWork()
            expect(bad.promotions==0,"nonmatched first appearance remains candidate")
            for index in 1...32 {
                let value=try input(index);good.receive(value);good.delivered(roundID:value.roundID);await good.waitForWork()
            }
            expect(good.promotions==31,"more than thirty within one hour pauses subsequent addition")
            expect(logs.contains("learn teacher=cloud decision=verified")
                && !logs.contains(where:{ $0.contains("CloudWrong") || $0.contains("ProductTerm") }),
                "positive learning logs categories while excluding candidate text")
            good.cancelWork();bad.cancelWork();await good.waitForCancellation();await bad.waitForCancellation()
            expect(positive.audio?.retainedBufferCount==0 && negative.audio?.retainedBufferCount==0,"both outcomes release RAM")
            // One T2 case combines positive/negative policy fixtures with the fake learning worker.
            let words = ["Figma", "Sketch", "Qoder"]
            let echoText = "Figma，Sketch，Qoder。"
            var t2Logs: [String] = []
            var t2Writes = 0
            let t2 = TeacherLearningRuntime(terms: { [] }, trace: { t2Logs.append($0) }, persist: { _, _, _ in t2Writes += 1; return true })
            t2.configure(recognize: { _, _, _ in "Qoder" }, cancel: {})
            t2.authorize(online: true, doubao: false)
            func t2Input(_ local: String, _ reference: String) throws -> EnhancementComparison {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                buffer.frameLength = 16_000
                for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.2 }
                let snapshot = try VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0, localHotwords: words)
                return .init(roundID: snapshot.sessionID, localText: local, referenceText: reference,
                    localAt: Date(), referenceAt: Date(), localConfidence: nil, source: .onlineAPI,
                    audio: DoubaoLearningAudio([try OwnedPCMBuffer(copying: buffer)]), snapshot: snapshot)
            }
            let echo = try t2Input(echoText, "打开设计")
            let different = try t2Input("甲乙丙丁", "ABCD")
            t2.receive(echo); t2.delivered(roundID: echo.roundID)
            t2.receive(different); t2.delivered(roundID: different.roundID)
            await t2.waitForWork()
            expect(RecognitionHotwords.isEcho(text: echoText, words: words, durationSeconds: 1)
                && !RecognitionHotwords.isEcho(text: echoText, words: words, durationSeconds: 2)
                && !RecognitionHotwords.isEcho(text: "打开Figma，Sketch，Qoder", words: words, durationSeconds: 1)
                && !RecognitionHotwords.isEcho(text: "Figma，Sketch", words: words, durationSeconds: 0.1)
                && TeacherLearningPolicy.tooDifferent(local: "甲乙丙丁", reference: "ABCD")
                && !TeacherLearningPolicy.tooDifferent(local: "打开项目。", reference: "打开项目！")
                && t2Writes == 0 && t2.promotions == 0
                && echo.audio?.retainedBufferCount == 0 && different.audio?.retainedBufferCount == 0
                && t2Logs.contains("learn teacher=cloud decision=echo") && t2Logs.contains("learn teacher=cloud decision=tooDifferent"),
                "T2 echo hides local projection and skips learning; normal speech survives and whole-sentence error skips")
            t2.cancelWork(); await t2.waitForCancellation()
        } catch { failures.append("teacher recheck: synthetic setup failed") }
        return failures
    }
}
