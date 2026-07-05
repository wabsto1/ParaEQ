import Accelerate
import Foundation

// MARK: - GraphicEQ node

struct GraphicEQNode: Codable, Equatable {
    var frequency: Float
    var gainDB: Float
}

// MARK: - Minimum-phase FIR design (cepstral method)
//
// Same approach as Equalizer APO's GraphicEQ: build the target magnitude on
// an FFT grid (log-frequency interpolation between nodes, flat outside),
// convert to minimum phase via the real cepstrum, take the first `taps`
// samples with a half-Hann tail window. Minimum phase keeps latency near
// zero (a linear-phase FIR of this length would add ~170 ms).

enum MinPhaseFIR {

    /// dB gain at `freq` from log-frequency linear interpolation of nodes.
    static func targetGainDB(nodes: [GraphicEQNode], atFrequency freq: Double) -> Double {
        let sorted = nodes.sorted { $0.frequency < $1.frequency }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if freq <= Double(first.frequency) { return Double(first.gainDB) }
        if freq >= Double(last.frequency) { return Double(last.gainDB) }
        for i in 1..<sorted.count {
            let f0 = Double(sorted[i - 1].frequency)
            let f1 = Double(sorted[i].frequency)
            if freq <= f1 {
                let t = (log(freq) - log(f0)) / (log(f1) - log(f0))
                return Double(sorted[i - 1].gainDB)
                    + t * (Double(sorted[i].gainDB) - Double(sorted[i - 1].gainDB))
            }
        }
        return Double(last.gainDB)
    }

    /// Design a minimum-phase FIR realizing the node curve.
    static func design(nodes: [GraphicEQNode], sampleRate: Double,
                       taps: Int = 16384) -> [Float] {
        let n = taps                    // FFT size (power of two)
        let logN = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetupD(logN, FFTRadix(kFFTRadix2)) else {
            return [1] + [Float](repeating: 0, count: taps - 1)
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        // 1. Target log-magnitude on the FFT grid (Hermitian-symmetric).
        var logMag = [Double](repeating: 0, count: n)
        for k in 0...(n / 2) {
            let freq = Double(k) * sampleRate / Double(n)
            let dB = targetGainDB(nodes: nodes, atFrequency: max(freq, 1.0))
            let lm = dB * log(10.0) / 20.0      // ln of linear magnitude
            logMag[k] = lm
            if k > 0 && k < n / 2 { logMag[n - k] = lm }
        }

        // Complex FFT helpers (imag = 0 layout; design-time only, cost is fine)
        var real = [Double](repeating: 0, count: n)
        var imag = [Double](repeating: 0, count: n)

        func fft(_ dir: FFTDirection) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPDoubleSplitComplex(realp: rp.baseAddress!,
                                                      imagp: ip.baseAddress!)
                    vDSP_fft_zipD(setup, &split, 1, logN, dir)
                }
            }
        }

        // 2. Real cepstrum = IFFT(log |H|)
        real = logMag
        imag = [Double](repeating: 0, count: n)
        fft(FFTDirection(FFT_INVERSE))
        var scale = 1.0 / Double(n)
        vDSP_vsmulD(real, 1, &scale, &real, 1, vDSP_Length(n))
        vDSP_vsmulD(imag, 1, &scale, &imag, 1, vDSP_Length(n))

        // 3. Fold: keep c[0] and c[n/2], double 1..n/2-1, zero the rest
        for k in 1..<(n / 2) { real[k] *= 2 }
        for k in (n / 2 + 1)..<n { real[k] = 0 }
        imag = [Double](repeating: 0, count: n)

        // 4. Back to frequency domain: complex log-spectrum → exp → spectrum
        fft(FFTDirection(FFT_FORWARD))
        for k in 0..<n {
            let m = exp(real[k])
            real[k] = m * cos(imag[k])
            imag[k] = m * sin(imag[k])
        }

        // 5. Impulse response = IFFT(spectrum), first `taps` samples
        fft(FFTDirection(FFT_INVERSE))
        vDSP_vsmulD(real, 1, &scale, &real, 1, vDSP_Length(n))

        var h = (0..<taps).map { Float(real[$0]) }
        // Half-Hann window over the final quarter to kill truncation ripple
        let fadeStart = taps * 3 / 4
        for i in fadeStart..<taps {
            let t = Double(i - fadeStart) / Double(taps - fadeStart)
            h[i] *= Float(0.5 * (1.0 + cos(.pi * t)))
        }
        return h
    }
}

// MARK: - Streaming partitioned FFT convolver
//
// Uniform-partition overlap-save with a fixed internal block of 512 samples;
// variable callback sizes are absorbed by input/output FIFOs at the cost of
// one block (~10.7 ms at 48 kHz) of latency. Stereo, shared or per-channel
// impulse response. Realtime-safe process(): no allocation, no locks.

final class FIRConvolver {
    static let blockSize = 512
    private let block = FIRConvolver.blockSize
    private let fftSize: Int             // 2 × block
    private let logN: vDSP_Length
    private let setup: FFTSetup
    private let partitions: Int

    // IR partition spectra per channel [channel][partition][fftSize re+im]
    private var irReal: [[[Float]]]
    private var irImag: [[[Float]]]

    // Per-channel streaming state
    private final class ChannelState {
        var histReal: [[Float]]           // ring of input spectra
        var histImag: [[Float]]
        var histIdx = 0
        var inFIFO: [Float]
        var inCount = 0
        var outFIFO: [Float]
        var outRead = 0
        var outWrite = 0
        var prevTail: [Float]             // last `block` input samples

        init(partitions: Int, fftSize: Int, block: Int, capacity: Int) {
            histReal = Array(repeating: [Float](repeating: 0, count: fftSize), count: partitions)
            histImag = Array(repeating: [Float](repeating: 0, count: fftSize), count: partitions)
            inFIFO = [Float](repeating: 0, count: capacity)
            outFIFO = [Float](repeating: 0, count: capacity)
            prevTail = [Float](repeating: 0, count: block)
            // Prime with one block of silence (the FIFO latency)
            outWrite = block
        }
    }
    private var channels: [ChannelState] = []
    private let fifoCapacity: Int

    // Scratch (single block, reused)
    private var scratchReal: [Float]
    private var scratchImag: [Float]
    private var accReal: [Float]
    private var accImag: [Float]

    var latency: Int { block }

    /// `irs`: one (mono, shared) or two (per-channel) impulse responses.
    init?(impulseResponses irs: [[Float]], maxFrames: Int = 4096) {
        guard let firstIR = irs.first, !firstIR.isEmpty else { return nil }
        fftSize = block * 2
        logN = vDSP_Length(log2(Double(fftSize)))
        guard let s = vDSP_create_fftsetup(logN, FFTRadix(kFFTRadix2)) else { return nil }
        setup = s
        let irLen = min(irs.map(\.count).max()!, 131_072)
        partitions = (irLen + block - 1) / block
        fifoCapacity = maxFrames + 2 * block

        // Precompute IR partition spectra
        irReal = []
        irImag = []
        scratchReal = [Float](repeating: 0, count: fftSize)
        scratchImag = [Float](repeating: 0, count: fftSize)
        accReal = [Float](repeating: 0, count: fftSize)
        accImag = [Float](repeating: 0, count: fftSize)

        for ch in 0..<2 {
            let ir = irs[min(ch, irs.count - 1)]
            var chReal: [[Float]] = []
            var chImag: [[Float]] = []
            for p in 0..<partitions {
                var re = [Float](repeating: 0, count: fftSize)
                var im = [Float](repeating: 0, count: fftSize)
                let start = p * block
                let count = min(block, ir.count - start)
                if count > 0 {
                    for i in 0..<count { re[i] = ir[start + i] }
                }
                fftInPlace(&re, &im, FFTDirection(FFT_FORWARD))
                chReal.append(re)
                chImag.append(im)
            }
            irReal.append(chReal)
            irImag.append(chImag)
        }
        channels = [
            ChannelState(partitions: partitions, fftSize: fftSize, block: block, capacity: fifoCapacity),
            ChannelState(partitions: partitions, fftSize: fftSize, block: block, capacity: fifoCapacity),
        ]
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    private func fftInPlace(_ re: inout [Float], _ im: inout [Float], _ dir: FFTDirection) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, logN, dir)
            }
        }
    }

    /// Process planar stereo in place.
    func process(l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>,
                 frames: Int) {
        processChannel(0, io: l, frames: frames)
        processChannel(1, io: r, frames: frames)
    }

    private func processChannel(_ ch: Int, io: UnsafeMutablePointer<Float>, frames: Int) {
        let st = channels[ch]
        var consumed = 0
        while consumed < frames {
            let chunk = min(frames - consumed, fifoCapacity - st.inCount)
            for i in 0..<chunk { st.inFIFO[st.inCount + i] = io[consumed + i] }
            st.inCount += chunk
            consumed += chunk

            // Process every complete block in the input FIFO
            var offset = 0
            while st.inCount - offset >= block {
                convolveBlock(st, ch: ch, input: st.inFIFO, at: offset)
                offset += block
            }
            if offset > 0 {
                for i in 0..<(st.inCount - offset) { st.inFIFO[i] = st.inFIFO[offset + i] }
                st.inCount -= offset
            }
        }
        // Emit `frames` from the output FIFO (primed with one block of zeros)
        for i in 0..<frames {
            if st.outRead < st.outWrite {
                io[i] = st.outFIFO[st.outRead % fifoCapacity]
                st.outRead += 1
            } else {
                io[i] = 0   // underrun (startup only)
            }
        }
        // Keep ring indices bounded
        if st.outRead >= fifoCapacity && st.outWrite >= fifoCapacity {
            st.outRead -= fifoCapacity
            st.outWrite -= fifoCapacity
        }
    }

    private func convolveBlock(_ st: ChannelState, ch: Int,
                               input: [Float], at offset: Int) {
        // Overlap-save frame: [previous block | current block]
        for i in 0..<block {
            scratchReal[i] = st.prevTail[i]
            scratchReal[block + i] = input[offset + i]
            st.prevTail[i] = input[offset + i]
        }
        for i in 0..<fftSize { scratchImag[i] = 0 }
        fftInPlace(&scratchReal, &scratchImag, FFTDirection(FFT_FORWARD))

        // Store spectrum in history ring (element-wise: array assignment
        // would trigger COW allocation on the audio thread)
        st.histIdx = (st.histIdx + 1) % partitions
        for i in 0..<fftSize {
            st.histReal[st.histIdx][i] = scratchReal[i]
            st.histImag[st.histIdx][i] = scratchImag[i]
        }

        // Accumulate partitions × history
        for i in 0..<fftSize { accReal[i] = 0; accImag[i] = 0 }
        for p in 0..<partitions {
            let hIdx = (st.histIdx - p + partitions * 2) % partitions
            let hr = st.histReal[hIdx]
            let hi = st.histImag[hIdx]
            let fr = irReal[ch][p]
            let fi = irImag[ch][p]
            for i in 0..<fftSize {
                accReal[i] += hr[i] * fr[i] - hi[i] * fi[i]
                accImag[i] += hr[i] * fi[i] + hi[i] * fr[i]
            }
        }

        fftInPlace(&accReal, &accImag, FFTDirection(FFT_INVERSE))
        // vDSP complex FFT round trip scales by fftSize
        let scale = 1.0 / Float(fftSize)
        // Overlap-save: second half is valid output
        for i in 0..<block {
            st.outFIFO[st.outWrite % fifoCapacity] = accReal[block + i] * scale
            st.outWrite += 1
        }
    }
}
