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

final class BandLayoutTests: XCTestCase {
    func testLayoutsProduceCorrectCounts() {
        for layout in BandLayout.allCases {
            let bands = makeDefaultBands(layout)
            XCTAssertEqual(bands.count, layout.rawValue)
            XCTAssertEqual(bands.first?.filterType, .lowShelf)
            XCTAssertEqual(bands.last?.filterType, .highShelf)
            // Frequencies strictly ascending within 20 Hz–20 kHz
            let freqs = bands.map(\.frequency)
            XCTAssertEqual(freqs, freqs.sorted())
            XCTAssertGreaterThanOrEqual(freqs.first!, 20)
            XCTAssertLessThanOrEqual(freqs.last!, 20000)
        }
    }

    func test31BandChainProcesses() throws {
        let eq = try XCTUnwrap(BiquadEQ(bands: makeDefaultBands(.thirtyOne),
                                        sampleRate: 48000))
        let frames = 2048
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
        // Flat 31-band chain stays transparent (accumulated float error only)
        for i in stride(from: 0, to: frames, by: 61) {
            XCTAssertEqual(outL[i], inp[i], accuracy: 5e-4)
        }
    }
}

final class CrossoverFilterTests: XCTestCase {
    private let fs: Double = 48000

    private func mag(_ type: FilterType, freq: Float, at f: Double) -> Double {
        let b = EQBand(frequency: freq, gain: 0, q: 1, filterType: type, enabled: true)
        return BiquadCoefficients.cascadeMagnitudeDB(for: b, atFrequency: f, sampleRate: fs)
    }

    func testButterworthCutoffIsMinus3dB() {
        for type in [FilterType.bwLowPass6, .bwLowPass24, .bwHighPass6, .bwHighPass24] {
            XCTAssertEqual(mag(type, freq: 1000, at: 1000), -3.01, accuracy: 0.15,
                           "\(type) at Fc")
        }
    }

    func testLinkwitzRileyCutoffIsMinus6dB() {
        for type in [FilterType.lrLowPass12, .lrLowPass24, .lrHighPass12, .lrHighPass24] {
            XCTAssertEqual(mag(type, freq: 1000, at: 1000), -6.02, accuracy: 0.15,
                           "\(type) at Fc")
        }
    }

    func testSlopes() {
        // Two octaves into the stopband, attenuation ≈ slope × 2
        XCTAssertEqual(mag(.bwLowPass6, freq: 500, at: 2000), -12, accuracy: 1.5)
        XCTAssertEqual(mag(.bwLowPass24, freq: 500, at: 2000), -48, accuracy: 2.5)
        XCTAssertEqual(mag(.lrLowPass12, freq: 500, at: 2000), -24, accuracy: 2.0)
        XCTAssertEqual(mag(.lrLowPass24, freq: 500, at: 2000), -48, accuracy: 2.5)
        XCTAssertEqual(mag(.bwHighPass24, freq: 2000, at: 500), -48, accuracy: 2.5)
    }

    func testPassbandsAreFlat() {
        XCTAssertEqual(mag(.bwLowPass24, freq: 5000, at: 100), 0, accuracy: 0.1)
        XCTAssertEqual(mag(.lrHighPass24, freq: 100, at: 5000), 0, accuracy: 0.1)
    }

    func testSectionCountExpandsForCascades() {
        var bands = makeDefaultBands()          // 10 single-section bands
        XCTAssertEqual(BiquadEQ.sectionCount(for: bands, sampleRate: fs), 10)
        bands[0].filterType = .bwHighPass24     // 2 sections
        bands[9].filterType = .lrLowPass24      // 2 sections
        XCTAssertEqual(BiquadEQ.sectionCount(for: bands, sampleRate: fs), 12)
        // update() must refuse a mismatched chain (engine rebuild required)
        let eq = BiquadEQ(bands: makeDefaultBands(), sampleRate: fs)!
        XCTAssertFalse(eq.update(bands: bands))
        XCTAssertTrue(eq.update(bands: makeDefaultBands()))
    }

    func testLR24CascadeProcessesAudio() throws {
        var bands = makeDefaultBands(.five)
        bands[0] = EQBand(frequency: 100, gain: 0, q: 1,
                          filterType: .lrHighPass24, enabled: true)
        let eq = try XCTUnwrap(BiquadEQ(bands: bands, sampleRate: fs))
        // A 30 Hz sine (well below the 100 Hz LR24 high-pass) should be
        // strongly attenuated end-to-end through the vDSP chain.
        let frames = 48000
        var inp = [Float](repeating: 0, count: frames)
        for i in 0..<frames { inp[i] = sinf(2 * .pi * 30 * Float(i) / Float(fs)) * 0.5 }
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
        func rms(_ x: ArraySlice<Float>) -> Float {
            sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
        }
        let attenuationDB = 20 * log10f(rms(outL[24000...]) / rms(inp[24000...]))
        XCTAssertLessThan(attenuationDB, -35, "30 Hz through 100 Hz LR24 HP")
    }
}

final class LimiterTests: XCTestCase {
    private func run(_ limiter: Limiter, input: [Float]) -> [Float] {
        var l = input
        var r = input
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                limiter.process(l: lp.baseAddress!, r: rp.baseAddress!,
                                frames: input.count)
            }
        }
        return l
    }

    func testOutputNeverExceedsCeiling() {
        let limiter = Limiter(sampleRate: 48000, ceiling: 0.985)
        // 2× overshoot sine
        let input = (0..<48000).map { sinf(2 * .pi * 440 * Float($0) / 48000) * 2.0 }
        let out = run(limiter, input: input)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 0.9851)
    }

    func testBelowThresholdIsTransparentAfterDelay() {
        let limiter = Limiter(sampleRate: 48000, ceiling: 0.985)
        let input = (0..<4800).map { sinf(2 * .pi * 440 * Float($0) / 48000) * 0.5 }
        let out = run(limiter, input: input)
        let delay = 240 // 5 ms at 48 kHz
        for i in stride(from: 0, to: input.count - delay, by: 37) {
            XCTAssertEqual(out[i + delay], input[i], accuracy: 1e-5,
                           "pure delay below threshold")
        }
    }

    func testLimitedSineKeepsShape() {
        // Unlike a clipper, a limiter scales the waveform: crest factor of a
        // steady limited sine stays ≈ √2 instead of flattening toward 1.
        let limiter = Limiter(sampleRate: 48000, ceiling: 0.985)
        let input = (0..<96000).map { sinf(2 * .pi * 440 * Float($0) / 48000) * 3.0 }
        let out = Array(run(limiter, input: input)[48000...])
        let peak = out.map { abs($0) }.max()!
        let rms = sqrtf(out.reduce(0) { $0 + $1 * $1 } / Float(out.count))
        XCTAssertEqual(peak / rms, sqrtf(2), accuracy: 0.05, "sine crest factor preserved")
    }

    func testImpulseIsCaught() {
        let limiter = Limiter(sampleRate: 48000, ceiling: 0.985)
        var input = [Float](repeating: 0.1, count: 4800)
        input[2400] = 4.0  // single-sample spike
        let out = run(limiter, input: input)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 0.9851,
                                 "lookahead catches single-sample transient")
    }
}

final class PerChannelTests: XCTestCase {
    private let fs: Double = 48000

    private func rms(_ x: ArraySlice<Float>) -> Float {
        sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
    }

    func testIndependentChannelBandSets() throws {
        // Left: +6 dB at 1 kHz. Right: -6 dB at 1 kHz. Same input both sides.
        var bandsL = makeDefaultBands(.five)
        var bandsR = makeDefaultBands(.five)
        bandsL[2] = EQBand(frequency: 1000, gain: 6, q: 1.41,
                           filterType: .parametric, enabled: true)
        bandsR[2] = EQBand(frequency: 1000, gain: -6, q: 1.41,
                           filterType: .parametric, enabled: true)
        let eq = try XCTUnwrap(BiquadEQ(bandsA: bandsL, bandsB: bandsR, sampleRate: fs))

        let frames = 48000
        let input = (0..<frames).map { sinf(2 * .pi * 1000 * Float($0) / Float(fs)) * 0.25 }
        var inp = input
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        inp.withUnsafeMutableBufferPointer { p in
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or2 in
                    eq.process(inL: p.baseAddress!, inR: p.baseAddress!,
                               outL: ol.baseAddress!, outR: or2.baseAddress!,
                               frames: frames)
                }
            }
        }
        let gL = 20 * log10f(rms(outL[24000...]) / rms(input[24000...]))
        let gR = 20 * log10f(rms(outR[24000...]) / rms(input[24000...]))
        XCTAssertEqual(gL, 6, accuracy: 0.2, "left channel runs its own set")
        XCTAssertEqual(gR, -6, accuracy: 0.2, "right channel runs its own set")
    }

    func testMismatchedSetLengthsPadWithUnity() throws {
        // 5-band left vs 10-band right must both stay transparent when flat.
        let eq = try XCTUnwrap(BiquadEQ(bandsA: makeDefaultBands(.five),
                                        bandsB: makeDefaultBands(.ten),
                                        sampleRate: fs))
        let frames = 4096
        var inp = (0..<frames).map { _ in Float.random(in: -0.5...0.5) }
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        inp.withUnsafeMutableBufferPointer { p in
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or2 in
                    eq.process(inL: p.baseAddress!, inR: p.baseAddress!,
                               outL: ol.baseAddress!, outR: or2.baseAddress!,
                               frames: frames)
                }
            }
        }
        for i in stride(from: 0, to: frames, by: 89) {
            XCTAssertEqual(outL[i], inp[i], accuracy: 5e-4)
            XCTAssertEqual(outR[i], inp[i], accuracy: 5e-4)
        }
    }
}

final class CrossfeedTests: XCTestCase {
    func testCrossfeedBleedsLowsNotHighs() {
        let fs: Double = 48000
        let cf = Crossfeed(mode: .chuMoy, sampleRate: fs)
        let frames = 48000
        // Right-only content: lows at 100 Hz
        var l = [Float](repeating: 0, count: frames)
        var r = (0..<frames).map { sinf(2 * .pi * 100 * Float($0) / Float(fs)) * 0.5 }
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                cf.process(l: lp.baseAddress!, r: rp.baseAddress!, frames: frames)
            }
        }
        func rms(_ x: ArraySlice<Float>) -> Float {
            sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
        }
        let bleedLowDB = 20 * log10f(rms(l[24000...]) / 0.3535)

        // Right-only content: highs at 8 kHz
        let cf2 = Crossfeed(mode: .chuMoy, sampleRate: fs)
        var l2 = [Float](repeating: 0, count: frames)
        var r2 = (0..<frames).map { sinf(2 * .pi * 8000 * Float($0) / Float(fs)) * 0.5 }
        l2.withUnsafeMutableBufferPointer { lp in
            r2.withUnsafeMutableBufferPointer { rp in
                cf2.process(l: lp.baseAddress!, r: rp.baseAddress!, frames: frames)
            }
        }
        let bleedHighDB = 20 * log10f(rms(l2[24000...]) / 0.3535)

        XCTAssertEqual(bleedLowDB, -9.5, accuracy: 1.5, "lows bleed at crossfeed level")
        XCTAssertLessThan(bleedHighDB, bleedLowDB - 15,
                          "highs shadowed by the head (low-pass leg)")
    }

    func testCrossfeedOffModeUnused() {
        // .off is never instantiated by the engine; sanity: mode exists
        XCTAssertEqual(CrossfeedMode.off.name, "Off")
        XCTAssertEqual(ChannelMode.allCases.count, 3)
    }
}

final class GraphicEQTests: XCTestCase {
    /// Frequency response of an FIR via direct DFT at one frequency.
    private func firResponseDB(_ h: [Float], freq: Double, fs: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * freq / fs
        for (n, tap) in h.enumerated() {
            re += Double(tap) * cos(w * Double(n))
            im -= Double(tap) * sin(w * Double(n))
        }
        return 20 * log10(max(sqrt(re * re + im * im), 1e-12))
    }

    func testMinPhaseFIRMatchesNodeTargets() {
        let nodes = [
            GraphicEQNode(frequency: 100, gainDB: 6),
            GraphicEQNode(frequency: 1000, gainDB: 0),
            GraphicEQNode(frequency: 10000, gainDB: -6),
        ]
        let h = MinPhaseFIR.design(nodes: nodes, sampleRate: 48000)
        XCTAssertEqual(firResponseDB(h, freq: 100, fs: 48000), 6, accuracy: 0.5)
        XCTAssertEqual(firResponseDB(h, freq: 1000, fs: 48000), 0, accuracy: 0.5)
        XCTAssertEqual(firResponseDB(h, freq: 10000, fs: 48000), -6, accuracy: 0.5)
        // Log-space interpolation midpoint ~ +3 dB at ~316 Hz
        XCTAssertEqual(firResponseDB(h, freq: 316, fs: 48000), 3, accuracy: 0.7)
    }

    func testMinPhaseEnergyIsFrontLoaded() {
        let nodes = [GraphicEQNode(frequency: 100, gainDB: 6),
                     GraphicEQNode(frequency: 10000, gainDB: -6)]
        let h = MinPhaseFIR.design(nodes: nodes, sampleRate: 48000)
        let firstEnergy = h[..<512].reduce(Float(0)) { $0 + $1 * $1 }
        let total = h.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(firstEnergy / total, 0.95,
                             "minimum phase concentrates energy at t=0 (low latency)")
    }

    func testGraphicEQParser() {
        let text = "GraphicEQ: 20 -1.2; 100 3.5; 1000 0.0; 20000 -4"
        let nodes = AutoEQParser.parseGraphicEQ(text)
        XCTAssertEqual(nodes?.count, 4)
        XCTAssertEqual(nodes?[1].frequency, 100)
        XCTAssertEqual(nodes?[1].gainDB, 3.5)
        XCTAssertNil(AutoEQParser.parseGraphicEQ("Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1"))
    }
}

final class ConvolverTests: XCTestCase {
    /// Push audio through in awkward chunk sizes to exercise the FIFOs.
    private func stream(_ conv: FIRConvolver, input: [Float], chunk: Int) -> [Float] {
        var l = input
        var r = input
        var i = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                while i < input.count {
                    let n = min(chunk, input.count - i)
                    conv.process(l: lp.baseAddress! + i, r: rp.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        return l
    }

    func testDeltaIRIsIdentityWithBlockLatency() throws {
        var ir = [Float](repeating: 0, count: 2048)
        ir[0] = 1.0
        let conv = try XCTUnwrap(FIRConvolver(impulseResponses: [ir]))
        let input = (0..<4096).map { _ in Float.random(in: -0.5...0.5) }
        let out = stream(conv, input: input, chunk: 480)  // non-power-of-two chunks
        let d = conv.latency
        for i in stride(from: 0, to: input.count - d, by: 53) {
            XCTAssertEqual(out[i + d], input[i], accuracy: 1e-4)
        }
    }

    func testScaledDelayedDelta() throws {
        var ir = [Float](repeating: 0, count: 1024)
        ir[100] = 0.5   // 0.5× gain, 100-sample delay
        let conv = try XCTUnwrap(FIRConvolver(impulseResponses: [ir]))
        let input = (0..<4096).map { sinf(Float($0) * 0.05) * 0.4 }
        let out = stream(conv, input: input, chunk: 512)
        let d = conv.latency + 100
        for i in stride(from: 0, to: input.count - d, by: 37) {
            XCTAssertEqual(out[i + d], input[i] * 0.5, accuracy: 1e-4)
        }
    }

    func testLongIRSpansPartitions() throws {
        // IR longer than one partition: two spikes 1000 samples apart
        var ir = [Float](repeating: 0, count: 1600)
        ir[0] = 1.0
        ir[1000] = -0.5
        let conv = try XCTUnwrap(FIRConvolver(impulseResponses: [ir]))
        var input = [Float](repeating: 0, count: 4096)
        input[0] = 1.0   // unit impulse in
        let out = stream(conv, input: input, chunk: 512)
        let d = conv.latency
        XCTAssertEqual(out[d], 1.0, accuracy: 1e-4)
        XCTAssertEqual(out[d + 1000], -0.5, accuracy: 1e-4)
        XCTAssertEqual(out[d + 500], 0, accuracy: 1e-4)
    }
}
