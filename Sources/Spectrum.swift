import Accelerate
import Foundation

// MARK: - Real-time spectrum capture (pre-EQ and post-EQ)
//
// The IO thread appends mono-mixed samples into two ring buffers (single
// writer, plain stores, no allocation, no locks). The UI timer snapshots
// the most recent window and runs a Hann-windowed FFT. A read can tear by
// a callback's worth of samples at the ring seam; the window function
// suppresses the discontinuity and it is invisible in a visualization.

final class SpectrumTap {
    let n = 2048                       // FFT window (power of two)
    private let mask: Int
    let sampleRate: Double

    private let preRing: UnsafeMutablePointer<Float>
    private let postRing: UnsafeMutablePointer<Float>
    private let preWritePtr: UnsafeMutablePointer<Int>
    private let postWritePtr: UnsafeMutablePointer<Int>

    // UI-thread FFT state
    private let fft: FFTSetup
    private let log2n: vDSP_Length
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mag2: [Float]
    private var smoothedPre: [Float] = []
    private var smoothedPost: [Float] = []

    /// dB where the display bottoms out.
    static let floorDB: Float = -90

    init?(sampleRate: Double) {
        guard sampleRate > 0 else { return nil }
        self.sampleRate = sampleRate
        mask = n - 1
        log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        fft = setup
        preRing = .allocate(capacity: n)
        preRing.initialize(repeating: 0, count: n)
        postRing = .allocate(capacity: n)
        postRing.initialize(repeating: 0, count: n)
        preWritePtr = .allocate(capacity: 1)
        preWritePtr.initialize(to: 0)
        postWritePtr = .allocate(capacity: 1)
        postWritePtr.initialize(to: 0)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mag2 = [Float](repeating: 0, count: n / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        preRing.deallocate()
        postRing.deallocate()
        preWritePtr.deallocate()
        postWritePtr.deallocate()
    }

    // MARK: IO thread (realtime-safe)

    func writePre(l: UnsafePointer<Float>, r: UnsafePointer<Float>, frames: Int) {
        var idx = preWritePtr.pointee
        for f in 0..<frames {
            preRing[idx & mask] = 0.5 * (l[f] + r[f])
            idx &+= 1
        }
        preWritePtr.pointee = idx
    }

    func writePost(l: UnsafePointer<Float>, r: UnsafePointer<Float>, frames: Int) {
        var idx = postWritePtr.pointee
        for f in 0..<frames {
            postRing[idx & mask] = 0.5 * (l[f] + r[f])
            idx &+= 1
        }
        postWritePtr.pointee = idx
    }

    // MARK: UI thread

    /// dB spectra sampled at `frequencies` (log-spaced display bins), with
    /// attack-instant / release-smoothed motion across calls.
    func analyze(frequencies: [Double]) -> (pre: [Float], post: [Float]) {
        if smoothedPre.count != frequencies.count {
            smoothedPre = [Float](repeating: Self.floorDB, count: frequencies.count)
            smoothedPost = [Float](repeating: Self.floorDB, count: frequencies.count)
        }
        let pre = spectrumDB(ring: preRing, writeIdx: preWritePtr.pointee,
                             frequencies: frequencies)
        let post = spectrumDB(ring: postRing, writeIdx: postWritePtr.pointee,
                              frequencies: frequencies)
        for i in 0..<frequencies.count {
            smoothedPre[i] = max(pre[i], smoothedPre[i] - 3.0)
            smoothedPost[i] = max(post[i], smoothedPost[i] - 3.0)
        }
        return (smoothedPre, smoothedPost)
    }

    private func spectrumDB(ring: UnsafePointer<Float>, writeIdx: Int,
                            frequencies: [Double]) -> [Float] {
        // Snapshot the most recent n samples in chronological order.
        let start = writeIdx - n
        for i in 0..<n {
            windowed[i] = ring[(start + i) & mask] * window[i]
        }
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cplx in
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!,
                                                    imagp: im.baseAddress!)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        // Reference so a 0 dBFS sine reads ~0 dB: for amplitude A at a bin
        // center, |X| = A·(Σwindow)/2·2(zrip) = A·N/2 with the denormalized
        // Hann window (Σw = N/2). Validated by unit test.
        let refDB = 20 * log10(Float(n) / 2)
        let binHz = sampleRate / Double(n)
        var out = [Float](repeating: Self.floorDB, count: frequencies.count)
        for (i, f) in frequencies.enumerated() {
            // Geometric-midpoint bin range around this display frequency.
            let fLo = i == 0 ? f : (frequencies[i - 1] * f).squareRoot()
            let fHi = i == frequencies.count - 1 ? f : (f * frequencies[i + 1]).squareRoot()
            var lo = Int(fLo / binHz)
            var hi = Int(fHi / binHz)
            lo = min(max(lo, 1), n / 2 - 1)
            hi = min(max(hi, lo), n / 2 - 1)
            var peak: Float = 0
            for b in lo...hi where mag2[b] > peak { peak = mag2[b] }
            let db = peak > 0 ? 10 * log10(peak) - refDB : Self.floorDB
            out[i] = max(db, Self.floorDB)
        }
        return out
    }
}
