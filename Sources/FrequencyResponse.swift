import Foundation

// MARK: - Frequency Response
//
// Evaluates the same BiquadCoefficients the audio engine runs, so the graph
// and auto-preamp match the actual processing exactly.

enum FrequencyResponse {

    /// Set by the engine to the tap's actual rate when running.
    static var sampleRate: Double = 48000

    /// Log-spaced frequencies from 20 Hz to 20 kHz.
    static func logFrequencies(count: Int) -> [Double] {
        let logMin = log10(20.0)
        let logMax = log10(20000.0)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return pow(10.0, logMin + t * (logMax - logMin))
        }
    }

    /// Magnitude in dB of a single band at a given frequency.
    static func magnitudeDB(for band: EQBand, atFrequency freq: Double) -> Double {
        guard band.enabled else { return 0 }
        return BiquadCoefficients.cascadeMagnitudeDB(
            for: band, atFrequency: freq, sampleRate: sampleRate)
    }

    /// Combined response curve across all bands (dB values at each log-spaced frequency).
    static func responseCurve(for bands: [EQBand], pointCount: Int) -> [Double] {
        let freqs = logFrequencies(count: pointCount)
        let coeffs = bands.filter(\.enabled).flatMap {
            BiquadCoefficients.cascade(for: $0, sampleRate: sampleRate)
        }
        return freqs.map { freq in
            coeffs.reduce(0.0) { sum, c in
                sum + c.magnitudeDB(atFrequency: freq, sampleRate: sampleRate)
            }
        }
    }

    /// Single band's response curve (dB values at each log-spaced frequency).
    static func bandCurve(for band: EQBand, pointCount: Int) -> [Double] {
        let freqs = logFrequencies(count: pointCount)
        return freqs.map { magnitudeDB(for: band, atFrequency: $0) }
    }

    /// Peak combined gain in dB across the audible range (used for auto-preamp).
    static func peakGainDB(for bands: [EQBand]) -> Float {
        let curve = responseCurve(for: bands, pointCount: 200)
        return Float(curve.max() ?? 0)
    }
}
