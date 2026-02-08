import Foundation

// MARK: - Frequency Response DSP

enum FrequencyResponse {

    /// Assumed sample rate for visualization.
    private static let sampleRate: Double = 48000

    /// Log-spaced frequencies from 20 Hz to 20 kHz.
    static func logFrequencies(count: Int) -> [Double] {
        let logMin = log10(20.0)
        let logMax = log10(20000.0)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return pow(10.0, logMin + t * (logMax - logMin))
        }
    }

    /// Magnitude in dB of a single band at a given frequency (Audio EQ Cookbook biquad math).
    static func magnitudeDB(for band: EQBand, atFrequency freq: Double) -> Double {
        guard band.enabled else { return 0 }

        let fs = sampleRate
        let f0 = Double(band.frequency)
        let Q = max(0.01, Double(band.q))
        let gainDB = Double(band.gain)
        let w0 = 2.0 * .pi * f0 / fs
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * Q)
        let A = pow(10.0, gainDB / 40.0) // sqrt of linear gain

        var b0: Double, b1: Double, b2: Double
        var a0: Double, a1: Double, a2: Double

        switch band.filterType {
        case .parametric:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosw0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosw0
            a2 = 1.0 - alpha / A

        case .lowShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 =       A * ((A + 1.0) - (A - 1.0) * cosw0 + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw0)
            b2 =       A * ((A + 1.0) - (A - 1.0) * cosw0 - twoSqrtAAlpha)
            a0 =             (A + 1.0) + (A - 1.0) * cosw0 + twoSqrtAAlpha
            a1 =    -2.0 * ((A - 1.0) + (A + 1.0) * cosw0)
            a2 =             (A + 1.0) + (A - 1.0) * cosw0 - twoSqrtAAlpha

        case .highShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 =       A * ((A + 1.0) + (A - 1.0) * cosw0 + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw0)
            b2 =       A * ((A + 1.0) + (A - 1.0) * cosw0 - twoSqrtAAlpha)
            a0 =             (A + 1.0) - (A - 1.0) * cosw0 + twoSqrtAAlpha
            a1 =     2.0 * ((A - 1.0) - (A + 1.0) * cosw0)
            a2 =             (A + 1.0) - (A - 1.0) * cosw0 - twoSqrtAAlpha

        case .lowPass:
            b0 = (1.0 - cosw0) / 2.0
            b1 =  1.0 - cosw0
            b2 = (1.0 - cosw0) / 2.0
            a0 =  1.0 + alpha
            a1 = -2.0 * cosw0
            a2 =  1.0 - alpha

        case .highPass:
            b0 =  (1.0 + cosw0) / 2.0
            b1 = -(1.0 + cosw0)
            b2 =  (1.0 + cosw0) / 2.0
            a0 =   1.0 + alpha
            a1 =  -2.0 * cosw0
            a2 =   1.0 - alpha

        case .bandPass:
            b0 =  alpha
            b1 =  0.0
            b2 = -alpha
            a0 =  1.0 + alpha
            a1 = -2.0 * cosw0
            a2 =  1.0 - alpha

        case .bandStop:
            b0 =  1.0
            b1 = -2.0 * cosw0
            b2 =  1.0
            a0 =  1.0 + alpha
            a1 = -2.0 * cosw0
            a2 =  1.0 - alpha
        }

        // Evaluate |H(e^jw)| at the query frequency
        let w = 2.0 * .pi * freq / fs
        let cosw = cos(w)
        let cos2w = cos(2.0 * w)
        let sinw = sin(w)
        let sin2w = sin(2.0 * w)

        let numReal = b0 / a0 + (b1 / a0) * cosw + (b2 / a0) * cos2w
        let numImag = (b1 / a0) * sinw + (b2 / a0) * sin2w
        let denReal = 1.0 + (a1 / a0) * cosw + (a2 / a0) * cos2w
        let denImag = (a1 / a0) * sinw + (a2 / a0) * sin2w

        let numMagSq = numReal * numReal + numImag * numImag
        let denMagSq = denReal * denReal + denImag * denImag

        guard denMagSq > 0 else { return 0 }
        let magSq = numMagSq / denMagSq
        guard magSq > 0 else { return -100 }
        return 10.0 * log10(magSq)
    }

    /// Combined response curve across all bands (dB values at each log-spaced frequency).
    static func responseCurve(for bands: [EQBand], pointCount: Int) -> [Double] {
        let freqs = logFrequencies(count: pointCount)
        return freqs.map { freq in
            bands.reduce(0.0) { sum, band in
                sum + magnitudeDB(for: band, atFrequency: freq)
            }
        }
    }

    /// Single band's response curve (dB values at each log-spaced frequency).
    static func bandCurve(for band: EQBand, pointCount: Int) -> [Double] {
        let freqs = logFrequencies(count: pointCount)
        return freqs.map { magnitudeDB(for: band, atFrequency: $0) }
    }
}
