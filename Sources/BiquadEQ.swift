import Accelerate
import Foundation

// MARK: - RBJ Audio-EQ-Cookbook biquad coefficients
//
// Single source of truth for the filter math: the audio engine runs these
// exact coefficients (via vDSP), and the response graph evaluates their
// transfer function — so what you see is precisely what you hear.

struct BiquadCoefficients {
    // Normalized by a0
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let unity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func compute(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        guard band.enabled else { return .unity }

        let f0 = min(max(Double(band.frequency), 10.0), sampleRate * 0.499)
        let Q = max(0.01, Double(band.q))
        let gainDB = Double(band.gain)
        let w0 = 2.0 * .pi * f0 / sampleRate
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

        return BiquadCoefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// |H(e^jw)| in dB at a given frequency.
    func magnitudeDB(atFrequency freq: Double, sampleRate: Double) -> Double {
        let w = 2.0 * .pi * freq / sampleRate
        let cosw = cos(w)
        let cos2w = cos(2.0 * w)
        let sinw = sin(w)
        let sin2w = sin(2.0 * w)

        let numReal = b0 + b1 * cosw + b2 * cos2w
        let numImag = b1 * sinw + b2 * sin2w
        let denReal = 1.0 + a1 * cosw + a2 * cos2w
        let denImag = a1 * sinw + a2 * sin2w

        let numMagSq = numReal * numReal + numImag * numImag
        let denMagSq = denReal * denReal + denImag * denImag
        guard denMagSq > 0 else { return 0 }
        let magSq = numMagSq / denMagSq
        guard magSq > 0 else { return -100 }
        return 10.0 * log10(magSq)
    }
}

// MARK: - Realtime stereo biquad chain (vDSP)
//
// vDSP_biquadm runs all sections per channel in one SIMD-optimized call and
// supports glitch-free coefficient updates: setTargets ramps the running
// coefficients toward the new values sample-by-sample on the render thread.

final class BiquadEQ {
    private let setup: vDSP_biquadm_Setup
    private let sections: Int
    private let channels = 2
    let sampleRate: Double

    init?(bands: [EQBand], sampleRate: Double) {
        self.sections = bands.count
        self.sampleRate = sampleRate
        let coeffs = Self.coefficientArray(for: bands, sampleRate: sampleRate, channels: channels)
        guard let setup = vDSP_biquadm_CreateSetup(
            coeffs, vDSP_Length(sections), vDSP_Length(channels)) else { return nil }
        self.setup = setup
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
    }

    /// Glitch-free live update; safe to call from the main thread while the
    /// render thread is processing (vDSP ramps toward the targets internally).
    func update(bands: [EQBand]) {
        guard bands.count == sections else { return }
        let coeffs = Self.coefficientArray(for: bands, sampleRate: sampleRate, channels: channels)
        vDSP_biquadm_SetTargetsDouble(setup, coeffs, 0.005, 0.05,
                                      0, vDSP_Length(sections), 0, vDSP_Length(channels))
    }

    /// Process planar stereo in place or out of place.
    func process(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 frames: Int) {
        var inputs: [UnsafePointer<Float>] = [inL, inR]
        var outputs: [UnsafeMutablePointer<Float>] = [outL, outR]
        inputs.withUnsafeMutableBufferPointer { inPtr in
            outputs.withUnsafeMutableBufferPointer { outPtr in
                vDSP_biquadm(setup, inPtr.baseAddress!, 1,
                             outPtr.baseAddress!, 1, vDSP_Length(frames))
            }
        }
    }

    /// 5 doubles per section per channel: [b0 b1 b2 a1 a2], identical for
    /// both channels of a stereo pair.
    private static func coefficientArray(for bands: [EQBand], sampleRate: Double,
                                         channels: Int) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(bands.count * channels * 5)
        for band in bands {
            let c = BiquadCoefficients.compute(for: band, sampleRate: sampleRate)
            for _ in 0..<channels {
                result.append(contentsOf: [c.b0, c.b1, c.b2, c.a1, c.a2])
            }
        }
        return result
    }
}
