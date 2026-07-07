import Foundation

// MARK: - Balance-calibration test signal
//
// Pink noise for per-ear level measurement: broadband (averages out narrow
// coupling resonances between earcup and mic) and gentler on drivers/ears
// than white noise. Generated sample-by-sample in the IO callback, so the
// generator is a value type with no allocation and no locks.

/// Deterministic pink-noise generator (xorshift64* white → Paul Kellet
/// 3-pole pink filter). Output is normalized to ~1.0 RMS (peaks ~±4), so
/// `sample * injectionAmplitude` has that amplitude as its RMS level.
struct PinkNoise {
    private var state: UInt64
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0

    init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        state = seed == 0 ? 1 : seed
    }

    /// Uniform white sample in -1...1.
    private mutating func white() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let r = state &* 2685821657736338717
        // Top 24 bits → [0, 1) → [-1, 1)
        return Float(r >> 40) * (2.0 / 16_777_216.0) - 1.0
    }

    /// Next pink sample (Paul Kellet economy filter, scaled to ~±1 peak).
    mutating func next() -> Float {
        let w = white()
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return (b0 + b1 + b2 + w * 0.1848) * 0.61
    }
}

enum MeasurementSignal {
    /// RMS level of the calibration stimulus: -20 dBFS (generators are
    /// unit-RMS). Loud enough for a healthy SNR over room noise at the mic,
    /// quiet enough to be comfortable at any listening volume; peaks stay
    /// under the limiter's ceiling.
    static let injectionAmplitude: Float = 0.1
}

// MARK: - Multitone stimulus
//
// The actual calibration stimulus: 8 log-spaced tones, 500 Hz–4 kHz. Room
// noise (fans, HVAC, traffic) is broadband and concentrated low; measuring
// only at these exact frequencies (Goertzel detection) ignores nearly all
// of it — roughly 20 dB better noise immunity than broadband RMS, which is
// what makes the measurement workable next to a running MacBook fan.

/// Sum-of-sines generator, unit RMS. A class so the IO callback mutates
/// phase state in place through stable storage (allocated once at setup).
final class MultiTone {
    /// 8 tones log-spaced over 3 octaves: 500·2^(3i/7) Hz.
    static let frequencies: [Double] = (0..<8).map { 500 * pow(2, 3 * Double($0) / 7) }

    private let count: Int
    private let increments: UnsafeMutablePointer<Double>
    private let phases: UnsafeMutablePointer<Double>
    /// Per-tone amplitude for unit total RMS: N tones of amplitude a sum to
    /// RMS a·√(N/2), so a = √(2/N).
    private let amplitude: Double

    init(sampleRate: Double) {
        let freqs = Self.frequencies
        count = freqs.count
        amplitude = (2.0 / Double(count)).squareRoot()
        increments = .allocate(capacity: count)
        phases = .allocate(capacity: count)
        for i in 0..<count {
            increments[i] = 2 * .pi * freqs[i] / sampleRate
            phases[i] = 0
        }
    }

    deinit {
        increments.deallocate()
        phases.deallocate()
    }

    /// Realtime-safe: no allocation, no locks.
    func next() -> Float {
        var s = 0.0
        for i in 0..<count {
            var p = phases[i] + increments[i]
            if p > 2 * .pi { p -= 2 * .pi }
            phases[i] = p
            s += sin(p)
        }
        return Float(s * amplitude)
    }
}
