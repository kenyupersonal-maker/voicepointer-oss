import Foundation
import VoicePointerCore

public enum AudioLevelBufferChecks {
    public static func run() -> [String] {
        let buffer = AudioLevelBuffer()
        var failures: [String] = []
        let first = buffer.beginCapture()
        buffer.set(0.7, generation: first)
        buffer.set(.infinity, generation: first)
        if buffer.get() != 0.7 || buffer.sampleCount() != 1 { failures.append("finite sample gate") }
        if !buffer.invalidate(generation: first) { failures.append("first invalidate") }
        if buffer.invalidate(generation: first) { failures.append("duplicate invalidate") }
        buffer.set(0.2, generation: first)
        if buffer.get() != 0 { failures.append("stale write after invalidate") }

        let second = buffer.beginCapture()
        if second == first || second == 0 { failures.append("generation monotonicity") }
        buffer.set(0.4, generation: first)
        if buffer.get() != 0 { failures.append("old generation contaminated new") }
        buffer.set(0.4, generation: second)
        if buffer.invalidate(generation: first) || buffer.get() != 0.4 {
            failures.append("old failure invalidated new capture")
        }
        buffer.endCapture()
        buffer.set(0.9, generation: second)
        if buffer.get() != 0 || buffer.sampleCount() != 2 { failures.append("end capture gate") }
        return failures
    }
}
