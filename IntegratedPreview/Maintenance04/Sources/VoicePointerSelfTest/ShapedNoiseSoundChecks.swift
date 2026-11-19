import Foundation
import VoicePointerCore

/// The Send sound is rendered from a spectral table at launch; a wrong band centre, level or
/// normalisation would silently change what the user picked by ear.
enum ShapedNoiseSoundChecks {
    static func run() -> [String] {
        var failures: [String] = []
        // One loud band (column 12 = 700 Hz x 2^(12/6) = 2800 Hz), everything else at the floor.
        let rows = 20
        let table = (0..<rows).map { _ in (0..<27).map { $0 == 12 ? Int8(0) : Int8(-120) } }
        let first = ShapedNoiseSound.render(halfDecibels: table)
        let second = ShapedNoiseSound.render(halfDecibels: table)
        if first.count != rows * 480 { failures.append("shaped noise length \(first.count) != \(rows * 480)") }
        if first != second { failures.append("shaped noise must be deterministic for a fixed seed") }
        let peak = first.reduce(Float(0)) { max($0, abs($1)) }
        if abs(20 * log10(Double(peak)) + 6) > 0.05 { failures.append("shaped noise peak \(peak) is not -6 dBFS") }
        // A narrow band around 2.8 kHz crosses zero about 2 x 2800 times per second.
        let body = first[1_000..<(first.count - 1_000)]
        var crossings = 0
        var previous = body.first ?? 0
        for value in body.dropFirst() {
            if (previous < 0) != (value < 0) { crossings += 1 }
            previous = value
        }
        let rate = Double(crossings) / (Double(body.count) / Double(ShapedNoiseSound.sampleRate))
        if rate < 4_500 || rate > 6_700 { failures.append("shaped noise band centre off: \(Int(rate)) crossings/s") }
        if !ShapedNoiseSound.render(halfDecibels: []).isEmpty
            || !ShapedNoiseSound.render(halfDecibels: [[0, 0], [0]]).isEmpty {
            failures.append("shaped noise must reject an empty or ragged table")
        }
        // Every shipped Send sound table must render to a real sound of its own length.
        for choice in SendSoundChoice.allCases {
            guard let table = choice.table else { continue }
            let samples = ShapedNoiseSound.render(halfDecibels: table)
            if samples.count != table.count * 480 || samples.allSatisfy({ $0 == 0 }) {
                failures.append("send sound \(choice.rawValue) does not render")
            }
        }
        // "轻息咻·长" is "轻息咻" stretched in time: 30-50 % more rows, and it dies away instead of
        // stopping at the level the original stops on (the original ends about 20 dB under its peak).
        if let arc = SendSoundChoice.breathArc.table, let long = SendSoundChoice.breathArcLong.table,
           let arcLast = arc.last, let longLast = long.last {
            let ratio = Double(long.count) / Double(arc.count)
            if ratio < 1.3 || ratio > 1.5 { failures.append("long breath arc is \(ratio)x as long, want 1.3-1.5x") }
            func power(_ row: [Int8]) -> Double { row.reduce(0.0) { $0 + pow(10, Double($1) / 20) } }
            let arcEnd = power(arcLast) / (arc.map(power).max() ?? 1)
            let longEnd = power(longLast) / (long.map(power).max() ?? 1)
            if longEnd > arcEnd * 0.1 { failures.append("long breath arc must end at least 10 dB softer than the original") }
            if longEnd > 0.001 { failures.append("long breath arc must end 30 dB under its peak or lower") }
        } else {
            failures.append("breath arc sounds need tables")
        }
        let suiteName = "vp.selftest.sendsound.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        if SendSoundChoice.load(from: suite) != .system { failures.append("send sound default must be system") }
        suite.set("unknown", forKey: SendSoundChoice.defaultsKey)
        if SendSoundChoice.load(from: suite) != .system { failures.append("unknown send sound must read as system") }
        SendSoundChoice.save(.flyBy, to: suite)
        if SendSoundChoice.load(from: suite) != .flyBy { failures.append("send sound choice must persist") }
        // The settings cards: every choice has its own short, neutral name and line, and the contour
        // drawn on a card is built from the same table the sound is rendered from.
        let titles = SendSoundChoice.allCases.map { $0.title }
        let blurbs = SendSoundChoice.allCases.map { $0.blurb }
        if Set(titles).count != titles.count || titles.contains(where: { $0.isEmpty }) {
            failures.append("send sound names must be non-empty and unique")
        }
        if Set(blurbs).count != blurbs.count || blurbs.contains(where: { $0.isEmpty }) {
            failures.append("send sound blurbs must be non-empty and unique")
        }
        let personalWords = ["我的", "你录", "用户", "照你", "照用户"]
        if (titles + blurbs).contains(where: { text in personalWords.contains(where: { text.contains($0) }) }) {
            failures.append("send sound names must stay neutral")
        }
        let shape: [[Int8]] = [[-120, -120], [-20, -120], [0, -120], [-60, -120]]
        let shapeBars = SoundEnvelope.bars(halfDecibels: shape, count: 4)
        if shapeBars.count != 4 || abs(shapeBars[2] - 1) > 0.001
            || !(shapeBars[0] < shapeBars[3] && shapeBars[3] < shapeBars[1] && shapeBars[1] < shapeBars[2]) {
            failures.append("sound envelope must follow the loudness of each row")
        }
        if !SoundEnvelope.bars(halfDecibels: [], count: 4).isEmpty
            || !SoundEnvelope.bars(halfDecibels: shape, count: 0).isEmpty
            || !SoundEnvelope.bars(linearLevels: [0, 0], count: 3).isEmpty {
            failures.append("sound envelope must reject empty, zero-width and silent input")
        }
        let levelBars = SoundEnvelope.bars(linearLevels: [0, 0.5, 1, 0.25], count: 4)
        if levelBars.count != 4 || levelBars[0] != 0 || abs(levelBars[2] - 1) > 0.001
            || !(levelBars[3] < levelBars[1] && levelBars[1] < levelBars[2]) {
            failures.append("sound envelope must follow linear levels")
        }
        for choice in SendSoundChoice.allCases {
            guard let choiceTable = choice.table else { continue }
            let drawn = SoundEnvelope.bars(halfDecibels: choiceTable, count: 28)
            if drawn.count != 28 || drawn.max() != 1 || drawn.contains(where: { $0 < 0 || $0 > 1 }) {
                failures.append("send sound \(choice.rawValue) must have a full-scale contour")
            }
        }
        return failures
    }
}
