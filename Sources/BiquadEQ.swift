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

    /// Cascade of biquad sections realizing this band. Simple types return a
    /// single section; Butterworth/Linkwitz-Riley orders return their stage
    /// cascade (fixed per-stage Q from the pole angles; LR = squared BW).
    static func cascade(for band: EQBand, sampleRate: Double) -> [BiquadCoefficients] {
        guard band.enabled else { return [.unity] }
        let f0 = min(max(Double(band.frequency), 10.0), sampleRate * 0.499)

        func stage(_ type: FilterType, q: Double) -> BiquadCoefficients {
            var b = band
            b.filterType = type
            b.q = Float(q)
            return compute(for: b, sampleRate: sampleRate)
        }
        func firstOrder(lowPass: Bool) -> BiquadCoefficients {
            let t = tan(.pi * f0 / sampleRate)
            let a1 = (t - 1.0) / (t + 1.0)
            return lowPass
                ? BiquadCoefficients(b0: t / (t + 1.0), b1: t / (t + 1.0), b2: 0, a1: a1, a2: 0)
                : BiquadCoefficients(b0: 1.0 / (t + 1.0), b1: -1.0 / (t + 1.0), b2: 0, a1: a1, a2: 0)
        }
        // 4th-order Butterworth per-stage Q from pole angles 22.5° / 67.5°
        let bw4Q: [Double] = [0.5412, 1.3066]

        switch band.filterType {
        case .bwLowPass6:   return [firstOrder(lowPass: true)]
        case .bwHighPass6:  return [firstOrder(lowPass: false)]
        case .bwLowPass24:  return bw4Q.map { stage(.lowPass, q: $0) }
        case .bwHighPass24: return bw4Q.map { stage(.highPass, q: $0) }
        case .lrLowPass12:  return [stage(.lowPass, q: 0.5)]
        case .lrHighPass12: return [stage(.highPass, q: 0.5)]
        case .lrLowPass24:  return [stage(.lowPass, q: 0.7071), stage(.lowPass, q: 0.7071)]
        case .lrHighPass24: return [stage(.highPass, q: 0.7071), stage(.highPass, q: 0.7071)]
        default:            return [compute(for: band, sampleRate: sampleRate)]
        }
    }

    /// Combined magnitude of a band's full cascade.
    static func cascadeMagnitudeDB(for band: EQBand, atFrequency freq: Double,
                                   sampleRate: Double) -> Double {
        cascade(for: band, sampleRate: sampleRate)
            .reduce(0) { $0 + $1.magnitudeDB(atFrequency: freq, sampleRate: sampleRate) }
    }

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

        // Crossover types are realized in cascade(); grouped here only for
        // switch exhaustiveness (single-section 2nd-order approximation).
        case .lowPass, .bwLowPass6, .bwLowPass24, .lrLowPass12, .lrLowPass24:
            b0 = (1.0 - cosw0) / 2.0
            b1 =  1.0 - cosw0
            b2 = (1.0 - cosw0) / 2.0
            a0 =  1.0 + alpha
            a1 = -2.0 * cosw0
            a2 =  1.0 - alpha

        case .highPass, .bwHighPass6, .bwHighPass24, .lrHighPass12, .lrHighPass24:
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

    /// Total biquad sections a band set needs (crossover types expand to
    /// multi-stage cascades).
    static func sectionCount(for bands: [EQBand], sampleRate: Double) -> Int {
        bands.reduce(0) { $0 + BiquadCoefficients.cascade(for: $1, sampleRate: sampleRate).count }
    }

    /// Sections required for a channel pair (each channel can carry its own
    /// band set; the shorter chain is padded with unity sections).
    static func sectionCount(bandsA: [EQBand], bandsB: [EQBand]?, sampleRate: Double) -> Int {
        max(sectionCount(for: bandsA, sampleRate: sampleRate),
            sectionCount(for: bandsB ?? bandsA, sampleRate: sampleRate))
    }

    /// `bandsB == nil` → both channels run bandsA (linked stereo).
    /// Otherwise channel 0 runs bandsA and channel 1 runs bandsB
    /// (independent L/R, or M/S when the caller encodes around process()).
    init?(bandsA: [EQBand], bandsB: [EQBand]? = nil, sampleRate: Double) {
        self.sections = Self.sectionCount(bandsA: bandsA, bandsB: bandsB, sampleRate: sampleRate)
        self.sampleRate = sampleRate
        let coeffs = Self.coefficientArray(bandsA: bandsA, bandsB: bandsB,
                                           sections: sections, sampleRate: sampleRate)
        guard let setup = vDSP_biquadm_CreateSetup(
            coeffs, vDSP_Length(sections), vDSP_Length(channels)) else { return nil }
        self.setup = setup
    }

    convenience init?(bands: [EQBand], sampleRate: Double) {
        self.init(bandsA: bands, bandsB: nil, sampleRate: sampleRate)
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
    }

    /// Glitch-free live update; safe to call from the main thread while the
    /// render thread is processing (vDSP ramps toward the targets internally).
    /// Returns false when the section count no longer matches (band count or
    /// a crossover type changed) — the caller must rebuild the engine.
    @discardableResult
    func update(bandsA: [EQBand], bandsB: [EQBand]? = nil) -> Bool {
        guard Self.sectionCount(bandsA: bandsA, bandsB: bandsB,
                                sampleRate: sampleRate) == sections else {
            return false
        }
        let coeffs = Self.coefficientArray(bandsA: bandsA, bandsB: bandsB,
                                           sections: sections, sampleRate: sampleRate)
        vDSP_biquadm_SetTargetsDouble(setup, coeffs, 0.005, 0.05,
                                      0, vDSP_Length(sections), 0, vDSP_Length(channels))
        return true
    }

    @discardableResult
    func update(bands: [EQBand]) -> Bool {
        update(bandsA: bands, bandsB: nil)
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

    /// 5 doubles per section per channel: [b0 b1 b2 a1 a2]. Cascade stages
    /// become consecutive sections; shorter chains are padded with unity.
    private static func coefficientArray(bandsA: [EQBand], bandsB: [EQBand]?,
                                         sections: Int, sampleRate: Double) -> [Double] {
        func flat(_ bands: [EQBand]) -> [BiquadCoefficients] {
            var list = bands.flatMap { BiquadCoefficients.cascade(for: $0, sampleRate: sampleRate) }
            while list.count < sections { list.append(.unity) }
            return list
        }
        let chainA = flat(bandsA)
        let chainB = flat(bandsB ?? bandsA)
        var result: [Double] = []
        for s in 0..<sections {
            for c in [chainA[s], chainB[s]] {
                result.append(contentsOf: [c.b0, c.b1, c.b2, c.a1, c.a2])
            }
        }
        return result
    }
}
