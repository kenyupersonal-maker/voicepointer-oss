import Foundation

/// The loudness contour of a short sound, sized for drawing (the settings cards for the Send sound).
/// Pure computation over the same tables the sound is rendered from, so the picture cannot drift
/// from what is heard.
public enum SoundEnvelope {
    /// `count` bars in 0...1 (1 = the loudest row) from a spectral table whose cells are half-decibels
    /// relative to the loudest cell. Empty for an empty table, a non-positive `count` or a silent table.
    public static func bars(halfDecibels table: [[Int8]], count: Int) -> [Float] {
        let power = table.map { row in row.reduce(0.0) { $0 + pow(10, Double($1) / 20) } }
        return bars(power: power, count: count)
    }

    /// The same for a list of linear amplitude levels (one per row).
    public static func bars(linearLevels levels: [Double], count: Int) -> [Float] {
        bars(power: levels.map { $0 * $0 }, count: count)
    }

    /// Each bar shows the loudest row of its slice; the square root of power is amplitude, and a
    /// 0.6 exponent keeps the quiet tail visible next to the peak.
    private static func bars(power: [Double], count: Int) -> [Float] {
        guard count > 0, let peak = power.max(), peak > 0 else { return [] }
        let rows = power.count
        return (0..<count).map { index in
            let lower = min(index * rows / count, rows - 1)
            let upper = min(max((index + 1) * rows / count, lower + 1), rows)
            let loudest = power[lower..<upper].max() ?? 0
            return Float(pow((loudest / peak).squareRoot(), 0.6))
        }
    }
}
