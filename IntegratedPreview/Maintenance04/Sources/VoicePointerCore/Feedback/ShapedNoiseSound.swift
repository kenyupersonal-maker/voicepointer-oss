import Foundation

/// Renders a short, noise-like UI sound (the Send "咻") from a compact spectral table.
///
/// The table has one row per 10 ms and one column per 1/6-octave band starting at 700 Hz; each cell
/// is the band's level in half-decibel steps relative to the loudest cell (0), down to -120 (-60 dB).
/// Every band is the same seeded white noise through two cascaded band-pass biquads, normalized to
/// unit RMS and scaled by its level (amplitude interpolated per sample between row centres). This mirrors the
/// offline sound-sketch tool that produced the tables, so what was chosen by ear is what the app
/// plays. Pure computation: no audio device, file, or clock is touched.
public enum ShapedNoiseSound {
    public static let sampleRate = 48_000
    public static let rowSeconds = 0.010
    public static let lowestCentre = 700.0
    public static let bandsPerOctave = 6.0

    /// Mono samples in -1...1 with the loudest sample at `peakDecibels` dBFS; empty for a malformed table.
    public static func render(
        halfDecibels table: [[Int8]],
        peakDecibels: Double = -6,
        seed: UInt32 = 0x51A7_CE11
    ) -> [Float] {
        guard let bandCount = table.first?.count, bandCount > 0, !table.isEmpty,
              table.allSatisfy({ $0.count == bandCount }) else { return [] }
        let hop = Int(rowSeconds * Double(sampleRate))
        let count = table.count * hop

        var noise = [Double](repeating: 0, count: count)
        var state = seed
        for index in 0..<count {
            state = 1_664_525 &* state &+ 1_013_904_223
            noise[index] = Double(Int32(bitPattern: state)) / Double(Int32.max)
        }

        // Two stages narrow the band, so each stage is a little wider than 1/6 octave on its own.
        let halfStep = pow(2, 1 / (2 * bandsPerOctave))
        let quality = 0.64 / (halfStep - 1 / halfStep)
        var output = [Double](repeating: 0, count: count)
        var band = [Double](repeating: 0, count: count)
        for column in 0..<bandCount {
            let centre = lowestCentre * pow(2, Double(column) / bandsPerOctave)
            guard centre < Double(sampleRate) * 0.45 else { continue }
            let coefficients = bandPass(centre: centre, quality: quality)
            band = noise
            filter(&band, coefficients)
            filter(&band, coefficients)
            var energy = 0.0
            for value in band { energy += value * value }
            let rms = (energy / Double(count)).squareRoot()
            guard rms > 0 else { continue }
            let amplitudes = table.map { pow(10, Double($0[column]) / 40) / rms }
            for index in 0..<count {
                let position = Double(index) / Double(hop) - 0.5
                let lower = min(max(Int(position.rounded(.down)), 0), table.count - 1)
                let upper = min(lower + 1, table.count - 1)
                let fraction = min(max(position - Double(lower), 0), 1)
                output[index] += band[index] * (amplitudes[lower] * (1 - fraction) + amplitudes[upper] * fraction)
            }
        }

        let fade = Int(0.006 * Double(sampleRate))
        for index in 0..<min(fade, count) {
            let ramp = Double(index) / Double(fade)
            output[index] *= ramp
            output[count - 1 - index] *= ramp
        }
        let peak = output.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return [Float](repeating: 0, count: count) }
        let scale = pow(10, peakDecibels / 20) / peak
        return output.map { Float($0 * scale) }
    }

    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    /// RBJ band-pass with 0 dB peak gain.
    private static func bandPass(centre: Double, quality: Double) -> Biquad {
        let omega = 2 * Double.pi * centre / Double(sampleRate)
        let alpha = sin(omega) / (2 * quality)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(omega) / a0, a2: (1 - alpha) / a0)
    }

    private static func filter(_ samples: inout [Double], _ c: Biquad) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in samples.indices {
            let input = samples[index]
            let result = c.b0 * input + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = input; y2 = y1; y1 = result
            samples[index] = result
        }
    }
}
