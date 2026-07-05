import XCTest
@testable import ParaEQ

final class BiquadCoefficientTests: XCTestCase {

    private let fs: Double = 48000

    private func band(_ type: FilterType, freq: Float, gain: Float = 0,
                      q: Float = 0.707, enabled: Bool = true) -> EQBand {
        EQBand(frequency: freq, gain: gain, q: q, filterType: type, enabled: enabled)
    }

    private func mag(_ b: EQBand, at freq: Double) -> Double {
        BiquadCoefficients.compute(for: b, sampleRate: fs)
            .magnitudeDB(atFrequency: freq, sampleRate: fs)
    }

    func testDisabledBandIsUnity() {
        let b = band(.parametric, freq: 1000, gain: 12, q: 1, enabled: false)
        for f in [20.0, 1000.0, 20000.0] {
            XCTAssertEqual(mag(b, at: f), 0, accuracy: 1e-9)
        }
    }

    func testPeakGainAtCenterFrequency() {
        for gain: Float in [-12, -6, 3, 6, 12] {
            let b = band(.parametric, freq: 1000, gain: gain, q: 1.41)
            XCTAssertEqual(mag(b, at: 1000), Double(gain), accuracy: 0.05,
                           "peak gain \(gain) dB at Fc")
            // Far away the peak filter should be flat
            XCTAssertEqual(mag(b, at: 20), 0, accuracy: 0.3)
            XCTAssertEqual(mag(b, at: 20000), 0, accuracy: 0.3)
        }
    }

    func testLowShelfAsymptotes() {
        let b = band(.lowShelf, freq: 200, gain: 6, q: 0.707)
        XCTAssertEqual(mag(b, at: 20), 6, accuracy: 0.3, "shelf plateau below Fc")
        XCTAssertEqual(mag(b, at: 10000), 0, accuracy: 0.3, "flat above Fc")
        XCTAssertEqual(mag(b, at: 200), 3, accuracy: 0.5, "half gain at Fc")
    }

    func testHighShelfAsymptotes() {
        let b = band(.highShelf, freq: 5000, gain: -6, q: 0.707)
        XCTAssertEqual(mag(b, at: 20000), -6, accuracy: 0.4)
        XCTAssertEqual(mag(b, at: 100), 0, accuracy: 0.3)
    }

    func testButterworthLowPassMinus3dBAtCutoff() {
        let b = band(.lowPass, freq: 1000, q: 0.7071)
        XCTAssertEqual(mag(b, at: 1000), -3.01, accuracy: 0.1)
        // 12 dB/oct: two octaves above ≈ -24 dB
        XCTAssertLessThan(mag(b, at: 4000), -20)
        XCTAssertEqual(mag(b, at: 50), 0, accuracy: 0.2)
    }

    func testHighPassMirrorsLowPass() {
        let b = band(.highPass, freq: 1000, q: 0.7071)
        XCTAssertEqual(mag(b, at: 1000), -3.01, accuracy: 0.1)
        XCTAssertLessThan(mag(b, at: 250), -20)
        XCTAssertEqual(mag(b, at: 20000), 0, accuracy: 0.5)
    }

    func testNotchKillsCenterFrequency() {
        let b = band(.bandStop, freq: 1000, q: 5)
        XCTAssertLessThan(mag(b, at: 1000), -40)
        XCTAssertEqual(mag(b, at: 100), 0, accuracy: 0.2)
    }

    func testResponseCurveSumsBands() {
        FrequencyResponse.sampleRate = fs
        let bands = [
            band(.parametric, freq: 100, gain: 6, q: 1.41),
            band(.parametric, freq: 100, gain: -2, q: 1.41),
        ]
        let curve = FrequencyResponse.responseCurve(for: bands, pointCount: 200)
        let freqs = FrequencyResponse.logFrequencies(count: 200)
        let idx = freqs.enumerated().min { abs($0.1 - 100) < abs($1.1 - 100) }!.0
        XCTAssertEqual(curve[idx], 4.0, accuracy: 0.1, "6 dB + (-2 dB) = 4 dB at 100 Hz")
    }

    func testAutoPreampMatchesPeakBoost() {
        FrequencyResponse.sampleRate = fs
        let bands = [band(.parametric, freq: 1000, gain: 7.5, q: 1.41)]
        XCTAssertEqual(FrequencyResponse.peakGainDB(for: bands), 7.5, accuracy: 0.1)
        XCTAssertEqual(FrequencyResponse.peakGainDB(for: [band(.parametric, freq: 1000)]), 0,
                       accuracy: 0.01, "flat EQ needs no preamp")
    }
}

final class BiquadEQProcessingTests: XCTestCase {
    /// End-to-end check of the realtime vDSP path: a 1 kHz sine through a
    /// +6 dB peak at 1 kHz should come out ~2× amplitude at steady state.
    func testVDSPChainAppliesGain() throws {
        let fs: Double = 48000
        var bands = makeDefaultBands()
        for i in bands.indices { bands[i].gain = 0 }
        bands[5] = EQBand(frequency: 1000, gain: 6, q: 1.41,
                          filterType: .parametric, enabled: true)
        let eq = try XCTUnwrap(BiquadEQ(bands: bands, sampleRate: fs))

        let frames = 48000
        var inL = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            inL[i] = sinf(2 * .pi * 1000 * Float(i) / Float(fs)) * 0.25
        }
        var inR = inL
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        inL.withUnsafeBufferPointer { l in
            inR.withUnsafeBufferPointer { r in
                outL.withUnsafeMutableBufferPointer { ol in
                    outR.withUnsafeMutableBufferPointer { or2 in
                        eq.process(inL: l.baseAddress!, inR: r.baseAddress!,
                                   outL: ol.baseAddress!, outR: or2.baseAddress!,
                                   frames: frames)
                    }
                }
            }
        }
        // Compare steady-state RMS over the last half
        func rms(_ x: ArraySlice<Float>) -> Float {
            sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
        }
        let gainDB = 20 * log10f(rms(outL[24000...]) / rms(inL[24000...]))
        XCTAssertEqual(gainDB, 6.0, accuracy: 0.2)
        XCTAssertEqual(rms(outR[24000...]), rms(outL[24000...]), accuracy: 1e-4,
                       "channels process identically")
    }

    func testFlatChainIsTransparent() throws {
        let fs: Double = 48000
        var bands = makeDefaultBands()
        for i in bands.indices { bands[i].gain = 0 }
        let eq = try XCTUnwrap(BiquadEQ(bands: bands, sampleRate: fs))

        let frames = 4096
        var inp = [Float](repeating: 0, count: frames)
        for i in 0..<frames { inp[i] = Float.random(in: -0.5...0.5) }
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        inp.withUnsafeBufferPointer { p in
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or2 in
                    eq.process(inL: p.baseAddress!, inR: p.baseAddress!,
                               outL: ol.baseAddress!, outR: or2.baseAddress!,
                               frames: frames)
                }
            }
        }
        // Zero-gain peak/shelf sections are unity, so output ≈ input.
        for i in stride(from: 0, to: frames, by: 97) {
            XCTAssertEqual(outL[i], inp[i], accuracy: 2e-4)
        }
    }
}

final class AutoEQParserTests: XCTestCase {
    func testParsesEqualizerAPOFormat() {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON PK Fc 105 Hz Gain -1.1 dB Q 0.70
        Filter 2: ON LSC Fc 105 Hz Gain 2.5 dB Q 0.71
        Filter 3: ON HSC Fc 10000 Hz Gain -4.0 dB Q 0.70
        Filter 4: OFF PK Fc 230 Hz Gain 1.0 dB Q 1.00
        """
        let result = AutoEQParser.parse(text)
        XCTAssertEqual(result.preamp, -6.4)
        XCTAssertEqual(result.bands.count, 4)
        XCTAssertEqual(result.originalCount, 4)
        XCTAssertEqual(result.bands[0].frequency, 105)
        XCTAssertEqual(result.bands[0].gain, -1.1)
        XCTAssertEqual(result.bands[0].q, 0.70)
        XCTAssertEqual(result.bands[0].filterType, .parametric)
        XCTAssertEqual(result.bands[1].filterType, .lowShelf)
        XCTAssertEqual(result.bands[2].filterType, .highShelf)
        XCTAssertFalse(result.bands[3].enabled)
    }

    func testBandwidthOctToQ() {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB BW Oct 1.0"
        let result = AutoEQParser.parse(text)
        XCTAssertEqual(result.bands.count, 1)
        // BW 1 octave → Q = sqrt(2)/(2-1) ≈ 1.414
        XCTAssertEqual(result.bands[0].q, 1.414, accuracy: 0.01)
    }

    func testIgnoresCommentsAndBlank() {
        let text = """
        # a comment

        Filter 1: ON PK Fc 100 Hz Gain 1.0 dB Q 1.00
        """
        XCTAssertEqual(AutoEQParser.parse(text).bands.count, 1)
    }
}
