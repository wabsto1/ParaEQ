import Accelerate
import XCTest

@testable import ParaEQ

// MARK: - Pink-noise measurement signal

final class PinkNoiseTests: XCTestCase {

    func testDeterministicForEqualSeeds() {
        var a = PinkNoise(seed: 42)
        var b = PinkNoise(seed: 42)
        for _ in 0..<1000 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testDifferentSeedsDiffer() {
        var a = PinkNoise(seed: 1)
        var b = PinkNoise(seed: 2)
        var same = true
        for _ in 0..<64 where a.next() != b.next() { same = false }
        XCTAssertFalse(same)
    }

    func testRMSNearUnity() {
        var g = PinkNoise(seed: 7)
        var sum: Double = 0
        let n = 48_000
        for _ in 0..<n {
            let s = Double(g.next())
            sum += s * s
        }
        let rms = sqrt(sum / Double(n))
        XCTAssert(rms > 0.7 && rms < 1.4, "rms \(rms) outside 0.7...1.4")
    }

    func testBoundedAmplitude() {
        var g = PinkNoise(seed: 9)
        for _ in 0..<200_000 {
            XCTAssertLessThan(abs(g.next()), 8.0)
        }
    }

    /// Pink noise has more energy per octave-band at low frequencies:
    /// compare 100–400 Hz against 3.2–12.8 kHz (equal log widths) at 48 kHz.
    func testSpectralTilt() {
        let n = 1 << 15
        var g = PinkNoise(seed: 3)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = g.next() }

        let log2n = vDSP_Length(log2(Double(n)))
        let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mag2 = [Float](repeating: 0, count: n / 2)
        samples.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cplx in
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        let binHz = 48_000.0 / Double(n)
        func bandEnergy(_ lo: Double, _ hi: Double) -> Double {
            let a = Int(lo / binHz), b = Int(hi / binHz)
            return (a..<b).reduce(0.0) { $0 + Double(mag2[$1]) }
        }
        // Pink noise: equal energy per equal *log* width, so these two
        // 2-octave bands hold equal total energy (white noise would put
        // ~15 dB more in the wide high band). Compare per-Hz density:
        // pink ⇒ ~15 dB low-band excess, white ⇒ ~0 dB.
        let lowDensity = bandEnergy(100, 400) / 300
        let highDensity = bandEnergy(3_200, 12_800) / 9_600
        let densityTiltDB = 10 * log10(lowDensity / highDensity)
        XCTAssert(densityTiltDB > 10 && densityTiltDB < 20,
                  "expected ~15 dB pink density tilt, got \(densityTiltDB) dB")
    }

    func testInjectionAmplitudeIsMinus20dBFS() {
        XCTAssertEqual(MeasurementSignal.injectionAmplitude, 0.1, accuracy: 1e-6)
    }
}

// MARK: - Band-limited RMS + balance recommendation

final class BalanceCalibrationTests: XCTestCase {
    private let sr = 48_000.0

    private func sine(_ freq: Double, amplitude: Float = 0.5,
                      seconds: Double = 2.0) -> [Float] {
        let n = Int(sr * seconds)
        return (0..<n).map { amplitude * Float(sin(2 * .pi * freq * Double($0) / sr)) }
    }

    func testInBandSineRMS() {
        // 0.5-amplitude sine → RMS 0.3536 → -9.03 dB; 1 kHz passes untouched.
        let db = BalanceCalibration.bandLimitedRMSdB(sine(1_000), sampleRate: sr)
        XCTAssertEqual(db, 20 * log10(0.5 / 2.0.squareRoot()), accuracy: 0.5)
    }

    func testOutOfBandRejection() {
        let inBand = BalanceCalibration.bandLimitedRMSdB(sine(1_000), sampleRate: sr)
        let low = BalanceCalibration.bandLimitedRMSdB(sine(50), sampleRate: sr)
        let high = BalanceCalibration.bandLimitedRMSdB(sine(12_000), sampleRate: sr)
        XCTAssertGreaterThan(inBand - low, 20, "50 Hz only \(inBand - low) dB down")
        XCTAssertGreaterThan(inBand - high, 20, "12 kHz only \(inBand - high) dB down")
    }

    func testSilenceHitsFloor() {
        let db = BalanceCalibration.bandLimitedRMSdB(
            [Float](repeating: 0, count: 4_800), sampleRate: sr)
        XCTAssertLessThanOrEqual(db, -120)
    }

    func testRecommendationEqualIsCentered() {
        let r = BalanceCalibration.recommendation(leftDB: -30, rightDB: -30)
        XCTAssertEqual(r.deltaDB, 0, accuracy: 1e-9)
        XCTAssertEqual(r.balance, 0)
    }

    func testRecommendationAttenuatesLouderSide() {
        // Left 2 dB louder → shift toward R (balance > 0), and the applied
        // linear gain on L (1 - balance) must equal exactly -2 dB.
        let r = BalanceCalibration.recommendation(leftDB: -28, rightDB: -30)
        XCTAssertEqual(r.deltaDB, 2, accuracy: 1e-9)
        XCTAssertGreaterThan(r.balance, 0)
        XCTAssertEqual(20 * log10(Double(1 - r.balance)), -2, accuracy: 1e-4)

        let l = BalanceCalibration.recommendation(leftDB: -33, rightDB: -30)
        XCTAssertLessThan(l.balance, 0)
        XCTAssertEqual(20 * log10(Double(1 + l.balance)), -3, accuracy: 1e-4)
    }

    func testRecommendationClamped() {
        let r = BalanceCalibration.recommendation(leftDB: 0, rightDB: -40)
        XCTAssertLessThanOrEqual(abs(r.balance), 0.5)
    }

    func testEndToEndDetectsKnownImbalance() {
        // Same pink noise, right copy scaled by 0.8 (-1.938 dB): the
        // measured delta must recover it closely.
        var g = PinkNoise(seed: 11)
        let n = Int(sr * 3)
        var left = [Float](repeating: 0, count: n)
        for i in 0..<n { left[i] = g.next() * 0.1 }
        let right = left.map { $0 * 0.8 }

        let lDB = BalanceCalibration.bandLimitedRMSdB(left, sampleRate: sr)
        let rDB = BalanceCalibration.bandLimitedRMSdB(right, sampleRate: sr)
        let expected = -20 * log10(0.8)
        XCTAssertEqual(lDB - rDB, expected, accuracy: 0.15)

        let rec = BalanceCalibration.recommendation(leftDB: lDB, rightDB: rDB)
        XCTAssertEqual(20 * log10(Double(1 - rec.balance)), -expected, accuracy: 0.2)
    }

    func testBlockStatsStationaryNoiseHasLowSpread() {
        var g = PinkNoise(seed: 5)
        let n = Int(sr * 3)
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n { s[i] = g.next() * 0.1 }
        let stats = BalanceCalibration.blockStats(s, sampleRate: sr)
        XCTAssertEqual(stats.meanDB,
                       BalanceCalibration.bandLimitedRMSdB(s, sampleRate: sr),
                       accuracy: 1.0)
        XCTAssertLessThan(stats.stdDB, 0.5, "std \(stats.stdDB) dB")
    }
}

// MARK: - Mic-capture ring buffer

final class MonoRingTests: XCTestCase {

    func testSnapshotReturnsRecentSamplesInOrder() {
        let ring = MonoRing(seconds: 1, sampleRate: 1_000)  // capacity ≥ 1000
        var chunk = (0..<600).map { Float($0) }
        chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, stride: 1, frames: 600) }
        chunk = (600..<1_200).map { Float($0) }
        chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, stride: 1, frames: 600) }

        // Last 500 samples must be 700...1199 in order (spans the wrap seam).
        let snap = ring.snapshot(seconds: 0.5)
        XCTAssertEqual(snap.count, 500)
        for (i, v) in snap.enumerated() {
            XCTAssertEqual(v, Float(700 + i))
        }
    }

    func testSnapshotClampedToCapacity() {
        let ring = MonoRing(seconds: 1, sampleRate: 1_000)
        let chunk = [Float](repeating: 1, count: 100)
        chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, stride: 1, frames: 100) }
        let snap = ring.snapshot(seconds: 100)   // absurd request
        XCTAssertLessThanOrEqual(snap.count, ring.capacity)
    }

    func testStridedWriteAveragesNothingButPicksChannel() {
        // stride 2 = interleaved stereo; the ring stores every `stride`-th
        // sample starting at the given pointer (caller pre-mixes if needed).
        let ring = MonoRing(seconds: 1, sampleRate: 100)
        let interleaved: [Float] = [1, -1, 2, -2, 3, -3, 4, -4]
        interleaved.withUnsafeBufferPointer { ring.write($0.baseAddress!, stride: 2, frames: 4) }
        XCTAssertEqual(ring.snapshot(seconds: 0.04), [1, 2, 3, 4])
    }

    func testLevelRMS() {
        let ring = MonoRing(seconds: 1, sampleRate: 1_000)
        let sine = (0..<1_000).map { Float(0.5 * sin(2 * .pi * 50 * Double($0) / 1_000)) }
        sine.withUnsafeBufferPointer { ring.write($0.baseAddress!, stride: 1, frames: 1_000) }
        XCTAssertEqual(ring.levelRMS(seconds: 0.5), 0.5 / Float(2.0.squareRoot()),
                       accuracy: 0.01)
    }
}

// MARK: - Multitone stimulus + Goertzel detection (noise-immune path)

final class MultiToneTests: XCTestCase {
    private let sr = 48_000.0

    func testUnitRMS() {
        let g = MultiTone(sampleRate: sr)
        var sum = 0.0
        let n = 96_000
        for _ in 0..<n {
            let s = Double(g.next())
            sum += s * s
        }
        let rms = (sum / Double(n)).squareRoot()
        XCTAssertEqual(rms, 1.0, accuracy: 0.05, "rms \(rms)")
    }

    func testBounded() {
        let g = MultiTone(sampleRate: sr)
        for _ in 0..<200_000 {
            XCTAssertLessThan(abs(g.next()), 8.0)
        }
    }

    func testDetectionRecoversGeneratorLevel() {
        let g = MultiTone(sampleRate: sr)
        var s = [Float](repeating: 0, count: Int(sr * 2))
        for i in 0..<s.count { s[i] = g.next() * 0.1 }   // -20 dBFS RMS
        let db = BalanceCalibration.tonePowerDB(s, sampleRate: sr)
        XCTAssertEqual(db, -20, accuracy: 0.5, "detected \(db) dB")
    }

    func testDetectionIgnoresBroadbandNoise() {
        // Stimulus at -20 dBFS buried in pink noise at -10 dBFS (10 dB
        // *louder*): tone detection must still recover the level within
        // a few tenths of a dB. Broadband RMS would be off by >9 dB.
        let g = MultiTone(sampleRate: sr)
        var pink = PinkNoise(seed: 21)
        var s = [Float](repeating: 0, count: Int(sr * 3))
        for i in 0..<s.count {
            s[i] = g.next() * 0.1 + pink.next() * 0.316
        }
        let db = BalanceCalibration.tonePowerDB(s, sampleRate: sr)
        XCTAssertEqual(db, -20, accuracy: 0.5, "detected \(db) dB under noise")
    }

    func testToneStatsSubtractAmbient() {
        // "Ambient" = noise only; measurement = tones + the same noise.
        var pinkA = PinkNoise(seed: 33)
        var ambient = [Float](repeating: 0, count: Int(sr * 1))
        for i in 0..<ambient.count { ambient[i] = pinkA.next() * 0.1 }
        let ambientDB = BalanceCalibration.tonePowerDB(ambient, sampleRate: sr)

        let g = MultiTone(sampleRate: sr)
        var pinkB = PinkNoise(seed: 34)
        var meas = [Float](repeating: 0, count: Int(sr * 3))
        for i in 0..<meas.count { meas[i] = g.next() * 0.1 + pinkB.next() * 0.1 }

        let stats = BalanceCalibration.toneStats(meas, sampleRate: sr,
                                                 ambientDB: ambientDB)
        XCTAssertEqual(stats.meanDB, -20, accuracy: 0.5)
        XCTAssertLessThan(stats.stdDB, 0.5)
    }

    func testEndToEndImbalanceUnderNoise() {
        // Left/right captures with a 1.5 dB level difference, both drowned
        // in unrelated pink noise. The recovered delta must match.
        let imbalance: Float = pow(10, -1.5 / 20)
        func capture(scale: Float, seed: UInt64) -> [Float] {
            let g = MultiTone(sampleRate: sr)
            var pink = PinkNoise(seed: seed)
            var s = [Float](repeating: 0, count: Int(sr * 3))
            for i in 0..<s.count { s[i] = g.next() * 0.1 * scale + pink.next() * 0.1 }
            return s
        }
        let l = BalanceCalibration.toneStats(capture(scale: 1, seed: 51),
                                             sampleRate: sr, ambientDB: -60)
        let r = BalanceCalibration.toneStats(capture(scale: imbalance, seed: 52),
                                             sampleRate: sr, ambientDB: -60)
        let rec = BalanceCalibration.recommendation(leftDB: l.meanDB, rightDB: r.meanDB)
        XCTAssertEqual(rec.deltaDB, 1.5, accuracy: 0.3)
    }
}

final class TrialStatsTests: XCTestCase {

    func testMeanAndSpread() {
        let stats = BalanceCalibration.trialStats([-47.0, -47.4, -46.6])
        XCTAssertEqual(stats.meanDB, -47.0, accuracy: 1e-9)
        XCTAssertEqual(stats.stdDB, 0.3266, accuracy: 1e-3)
    }

    func testSingleTrial() {
        let stats = BalanceCalibration.trialStats([-30])
        XCTAssertEqual(stats.meanDB, -30)
        XCTAssertEqual(stats.stdDB, 0)
    }

    func testEmpty() {
        XCTAssertEqual(BalanceCalibration.trialStats([]).meanDB,
                       BalanceCalibration.floorDB)
    }
}

// MARK: - Robust per-tone statistics

final class RobustToneTests: XCTestCase {
    private let sr = 48_000.0

    func testMedian() {
        XCTAssertEqual(BalanceCalibration.median([3, 1, 2]), 2)
        XCTAssertEqual(BalanceCalibration.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(BalanceCalibration.median([]), BalanceCalibration.floorDB)
    }

    func testToneLevelsIsolatePerTone() {
        // A sine at exactly tone #2's frequency: its bin reads the sine's
        // RMS; every other tone bin stays ≥ 30 dB down.
        let f = MultiTone.frequencies[2]
        let n = Int(sr * 1)
        let s = (0..<n).map { Float(0.2 * sin(2 * .pi * f * Double($0) / sr)) }
        let levels = BalanceCalibration.toneLevelsDB(s, sampleRate: sr)
        XCTAssertEqual(levels[2], 20 * log10(0.2 / 2.0.squareRoot()), accuracy: 0.3)
        for (i, db) in levels.enumerated() where i != 2 {
            XCTAssertLessThan(db, levels[2] - 30, "tone \(i) leaked: \(db) dB")
        }
    }

    func testRobustToneLevelsRejectCorruptedBlock() {
        // 3 s of tones at -20 dBFS with one 0.5 s block trashed by loud
        // noise: block-median per tone must stay within 0.3 dB of clean.
        let g = MultiTone(sampleRate: sr)
        let n = Int(sr * 3)
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n { s[i] = g.next() * 0.1 }
        var pink = PinkNoise(seed: 77)
        let burstStart = Int(sr * 1.0), burstEnd = Int(sr * 1.5)
        for i in burstStart..<burstEnd { s[i] += pink.next() * 0.5 }

        let ambient = [Double](repeating: -100, count: MultiTone.frequencies.count)
        let levels = BalanceCalibration.robustToneLevels(s, sampleRate: sr,
                                                         ambientToneDBs: ambient)
        for db in levels {
            XCTAssertEqual(db, -20 - 10 * log10(Double(MultiTone.frequencies.count)),
                           accuracy: 0.4, "per-tone \(db)")
        }
    }

    func testMedianToneDeltaRejectsKilledTone() {
        // True imbalance 1.5 dB, but one tone in the right capture is
        // notched 10 dB (seating leak). Median delta ignores it; a mean
        // would be off by 10/8 = 1.25 dB.
        let left = [Double](repeating: -40, count: 8)
        var right = left.map { $0 - 1.5 }
        right[3] -= 10
        let delta = BalanceCalibration.medianToneDelta(left: left, right: right)
        XCTAssertEqual(delta, 1.5, accuracy: 1e-9)
    }
}
