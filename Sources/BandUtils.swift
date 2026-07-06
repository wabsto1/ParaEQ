import Foundation

// MARK: - Q ↔ bandwidth-in-octaves conversion (RBJ Audio-EQ-Cookbook)
//
// 1/Q = 2·sinh(ln2/2 · BW), so the two representations are exactly
// interchangeable for peaking filters.

enum Bandwidth {
    static func octaves(fromQ q: Float) -> Float {
        guard q > 0 else { return 0 }
        return Float(2.0 / log(2.0) * asinh(1.0 / (2.0 * Double(q))))
    }

    static func q(fromOctaves bw: Float) -> Float {
        guard bw > 0 else { return 0 }
        return Float(1.0 / (2.0 * sinh(log(2.0) / 2.0 * Double(bw))))
    }

    static func octaveLabel(forQ q: Float) -> String {
        String(format: "%.2f oct", octaves(fromQ: q))
    }
}

// MARK: - Suggested band placement
//
// Finds the widest gap (in octaves) between existing band frequencies —
// including the 20 Hz / 20 kHz edges — and returns a peaking band centered
// in it, with Q matched to the gap width so the new band roughly fills it.

func makeSuggestedBand(existing: [EQBand]) -> EQBand {
    let edges = [log2(20.0), log2(20000.0)]
    let logs = (edges + existing.map { log2(Double($0.frequency)) })
        .sorted()
    var bestCenter = log2(1000.0)
    var bestGap = 0.0
    for i in 1..<logs.count {
        let gap = logs[i] - logs[i - 1]
        if gap > bestGap {
            bestGap = gap
            bestCenter = (logs[i] + logs[i - 1]) / 2
        }
    }
    let freq = Float(min(max(pow(2.0, bestCenter), 20), 20000))
    let q = bestGap > 0
        ? min(max(Bandwidth.q(fromOctaves: Float(bestGap)), 0.5), 10)
        : Float(1.41)
    return EQBand(frequency: freq, gain: 0, q: q,
                  filterType: .parametric, enabled: true)
}

// MARK: - Graph gain range
//
// The response graph can show ±6/12/18/24 dB, or auto-scale to the smallest
// range that contains the current curve (with a little headroom).

enum GraphRange {
    static let choices: [Double] = [6, 12, 18, 24]

    /// Smallest standard range that fits `peakAbsDB` with 1 dB headroom.
    static func auto(forPeakAbsDB peakAbsDB: Double) -> Double {
        for r in choices where peakAbsDB + 1.0 <= r { return r }
        return choices.last!
    }
}
