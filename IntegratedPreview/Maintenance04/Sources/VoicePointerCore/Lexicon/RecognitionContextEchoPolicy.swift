import Foundation

public enum RecognitionContextEchoPolicy {
    public static func shouldDrop(text: String, plan: RecognitionContextPlan?, peak: Float?) -> Bool {
        guard let peak, peak.isFinite, peak >= 0, peak <= SilentTranscriptPolicy.noiseCeiling,
              let plan else { return false }
        func letters(_ value: String) -> [Character] { Array(value.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let transcript = letters(text)
        guard !transcript.isEmpty else { return false }
        let hints = (plan.terms + plan.recent).map(letters).filter { !$0.isEmpty }
        // Longest common contiguous run, not scattered individual common letters.
        // Transcript/plan are bounded before this O(n*m), executed only near silence.
        guard transcript.count <= 4096 else { return false }
        let required = Int(ceil(Double(transcript.count) * 0.7))
        for hint in hints {
            var previous = Array(repeating: 0, count: hint.count + 1)
            for character in transcript {
                var row = Array(repeating: 0, count: hint.count + 1)
                for index in hint.indices where hint[index] == character {
                    row[index + 1] = previous[index] + 1
                    if row[index + 1] >= required { return true }
                }
                previous = row
            }
        }
        return false
    }
}
