import Foundation

// MARK: - Balance-calibration analysis (offline, UI thread)
//
// Level comparison between the two earcup captures is done on a 250 Hz–4 kHz
// band: low frequencies depend heavily on the cup-to-mic seal and highs on
// exact positioning, while the midband couples repeatably. The band-pass is
// built from the same RBJ cascades the EQ uses (LR24 high-pass + LR24
// low-pass) applied offline as scalar Direct-Form-I sections.

enum BalanceCalibration {
    static let bandLow = 250.0
    static let bandHigh = 4_000.0
    /// dB returned for silence (below any real measurement).
    static let floorDB = -160.0

    /// RMS level in dBFS of the 250 Hz–4 kHz band of `samples`.
    static func bandLimitedRMSdB(_ samples: [Float], sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return floorDB }
        let filtered = bandpass(samples, sampleRate: sampleRate)
        var sum = 0.0
        for s in filtered { sum += Double(s) * Double(s) }
        let rms = (sum / Double(filtered.count)).squareRoot()
        return rms > 0 ? max(20 * log10(rms), floorDB) : floorDB
    }

    // MARK: Tone-bin detection (noise-immune measurement path)

    /// Combined RMS level in dB of the stimulus tones only, measured by
    /// Goertzel detection at each exact tone frequency. Broadband room
    /// noise (fan, HVAC) contributes almost nothing outside these bins,
    /// which is what makes the measurement robust in a normal room.
    static func tonePowerDB(_ samples: [Float], sampleRate: Double,
                            frequencies: [Double] = MultiTone.frequencies) -> Double {
        let n = samples.count
        guard n > 0 else { return floorDB }
        var totalPower = 0.0   // sum of per-tone RMS²
        for f in frequencies {
            let w = 2 * .pi * f / sampleRate
            let coeff = 2 * cos(w)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            for x in samples {
                s0 = Double(x) + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            // |X|² for the DFT-like sum; a sine of amplitude a at f gives
            // |X| = a·N/2, so its RMS² (a²/2) = 2|X|²/N².
            let magSq = s1 * s1 + s2 * s2 - coeff * s1 * s2
            totalPower += 2 * magSq / (Double(n) * Double(n))
        }
        return totalPower > 0 ? max(10 * log10(totalPower), floorDB) : floorDB
    }

    /// Per-tone RMS levels in dB (one Goertzel per stimulus frequency).
    static func toneLevelsDB(_ samples: [Float], sampleRate: Double,
                             frequencies: [Double] = MultiTone.frequencies) -> [Double] {
        let n = samples.count
        guard n > 0 else { return frequencies.map { _ in floorDB } }
        return frequencies.map { f in
            let w = 2 * .pi * f / sampleRate
            let coeff = 2 * cos(w)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            for x in samples {
                s0 = Double(x) + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let magSq = s1 * s1 + s2 * s2 - coeff * s1 * s2
            let power = 2 * magSq / (Double(n) * Double(n))
            return power > 0 ? max(10 * log10(power), floorDB) : floorDB
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return floorDB }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Per-tone trial levels, robust to movement during the capture: the
    /// capture is split into 0.5 s blocks, each tone's level is the median
    /// across blocks (a bumped block can't drag the level), and the ambient
    /// per-tone power is subtracted.
    static func robustToneLevels(_ samples: [Float], sampleRate: Double,
                                 ambientToneDBs: [Double]) -> [Double] {
        let freqs = MultiTone.frequencies
        let block = Int(sampleRate / 2)
        var perToneBlocks = [[Double]](repeating: [], count: freqs.count)
        var start = 0
        while start + block <= samples.count {
            let levels = toneLevelsDB(Array(samples[start..<(start + block)]),
                                      sampleRate: sampleRate, frequencies: freqs)
            for (i, db) in levels.enumerated() { perToneBlocks[i].append(db) }
            start += block
        }
        guard !perToneBlocks[0].isEmpty else {
            return toneLevelsDB(samples, sampleRate: sampleRate)
        }
        return (0..<freqs.count).map { i in
            let medDB = median(perToneBlocks[i])
            let ambient = i < ambientToneDBs.count
                ? pow(10, ambientToneDBs[i] / 10) : 0
            let power = max(pow(10, medDB / 10) - ambient, 1e-16)
            return 10 * log10(power)
        }
    }

    /// L−R difference per tone, condensed by median — a seating that kills
    /// one tone (leak, cancellation at that frequency) can't skew the result.
    static func medianToneDelta(left: [Double], right: [Double]) -> Double {
        median(zip(left, right).map { $0 - $1 })
    }

    /// Tone-level statistics across 0.5 s blocks with the ambient tone-bin
    /// power subtracted (power domain) from each block. `ambientDB` comes
    /// from a capture taken before the stimulus starts.
    static func toneStats(_ samples: [Float], sampleRate: Double,
                          ambientDB: Double)
        -> (meanDB: Double, stdDB: Double)
    {
        let block = Int(sampleRate / 2)
        let ambientPower = pow(10, ambientDB / 10)
        var levels: [Double] = []
        var start = 0
        while start + block <= samples.count {
            let db = tonePowerDB(Array(samples[start..<(start + block)]),
                                 sampleRate: sampleRate)
            let power = max(pow(10, db / 10) - ambientPower, 1e-16)
            levels.append(10 * log10(power))
            start += block
        }
        guard !levels.isEmpty else {
            return (tonePowerDB(samples, sampleRate: sampleRate), 0)
        }
        let mean = levels.reduce(0, +) / Double(levels.count)
        let variance = levels.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(levels.count)
        return (mean, variance.squareRoot())
    }

    /// Mean and spread of the band level across 0.5 s blocks (first block
    /// dropped for filter settling). The spread is the repeatability signal
    /// shown to the user ("±0.2 dB" vs "re-seat and try again").
    static func blockStats(_ samples: [Float], sampleRate: Double)
        -> (meanDB: Double, stdDB: Double)
    {
        let block = Int(sampleRate / 2)
        let filtered = bandpass(samples, sampleRate: sampleRate)
        var levels: [Double] = []
        var start = block   // skip first block: filter transient
        while start + block <= filtered.count {
            var sum = 0.0
            for i in start..<(start + block) {
                sum += Double(filtered[i]) * Double(filtered[i])
            }
            let rms = (sum / Double(block)).squareRoot()
            levels.append(rms > 0 ? 20 * log10(rms) : floorDB)
            start += block
        }
        guard !levels.isEmpty else {
            return (bandLimitedRMSdB(samples, sampleRate: sampleRate), 0)
        }
        let mean = levels.reduce(0, +) / Double(levels.count)
        let variance = levels.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(levels.count)
        return (mean, variance.squareRoot())
    }

    /// Aggregates repeated per-ear trials (re-seated between measurements):
    /// mean of the trial levels, and the trial-to-trial spread — the honest
    /// repeatability figure, since re-seating dominates the error budget.
    static func trialStats(_ trialDBs: [Double]) -> (meanDB: Double, stdDB: Double) {
        guard !trialDBs.isEmpty else { return (floorDB, 0) }
        let mean = trialDBs.reduce(0, +) / Double(trialDBs.count)
        let variance = trialDBs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(trialDBs.count)
        return (mean, variance.squareRoot())
    }

    /// Balance correction for a measured L/R level difference. The engine
    /// applies balance as linear attenuation of one side (gL = 1-b for b>0,
    /// gR = 1+b for b<0), so the louder side gets exactly -|delta| dB.
    /// Clamped to ±0.5 (≈6 dB) — anything larger means a broken cable or a
    /// bad measurement, not a trim.
    static func recommendation(leftDB: Double, rightDB: Double)
        -> (deltaDB: Double, balance: Float)
    {
        recommendation(deltaDB: leftDB - rightDB)
    }

    static func recommendation(deltaDB delta: Double)
        -> (deltaDB: Double, balance: Float)
    {
        let attenuation = 1 - pow(10, -abs(delta) / 20)
        let balance = Float(delta >= 0 ? attenuation : -attenuation)
        return (delta, min(max(balance, -0.5), 0.5))
    }

    // MARK: Offline filtering

    private static func bandpass(_ samples: [Float], sampleRate: Double) -> [Float] {
        let hp = EQBand(frequency: Float(bandLow), gain: 0, q: 0.7071,
                        filterType: .lrHighPass24, enabled: true)
        let lp = EQBand(frequency: Float(bandHigh), gain: 0, q: 0.7071,
                        filterType: .lrLowPass24, enabled: true)
        let sections = BiquadCoefficients.cascade(for: hp, sampleRate: sampleRate)
            + BiquadCoefficients.cascade(for: lp, sampleRate: sampleRate)
        var out = samples
        for c in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<out.count {
                let x = Double(out[i])
                let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                x2 = x1; x1 = x
                y2 = y1; y1 = y
                out[i] = Float(y)
            }
        }
        return out
    }
}
