import XCTest
@testable import ParaEQ

// Tests for the v2.1 feature set: bandwidth conversion, suggested band
// placement, graph auto-range, undo history, and the spectrum analyzer.

final class BandwidthConversionTests: XCTestCase {

    func testKnownValues() {
        // Q = 1.414 (default) ≈ 1 octave; RBJ relation.
        XCTAssertEqual(Bandwidth.octaves(fromQ: 1.414), 1.0, accuracy: 0.01)
        // One-third octave graphic EQ Q ≈ 4.32.
        XCTAssertEqual(Bandwidth.octaves(fromQ: 4.32), 1.0 / 3.0, accuracy: 0.01)
    }

    func testRoundTrip() {
        for q: Float in [0.1, 0.5, 0.707, 1.41, 4.32, 10, 30] {
            let bw = Bandwidth.octaves(fromQ: q)
            XCTAssertEqual(Bandwidth.q(fromOctaves: bw), q, accuracy: q * 0.001)
        }
    }

    func testDegenerateInputs() {
        XCTAssertEqual(Bandwidth.octaves(fromQ: 0), 0)
        XCTAssertEqual(Bandwidth.q(fromOctaves: 0), 0)
    }
}

final class SuggestedBandTests: XCTestCase {

    func testFillsLargestGap() {
        // Bands at 100 and 10k: largest gap is 100 Hz–10 kHz;
        // its log-midpoint is 1 kHz.
        let existing = [
            EQBand(frequency: 100, gain: 0, q: 1, filterType: .parametric, enabled: true),
            EQBand(frequency: 10000, gain: 0, q: 1, filterType: .parametric, enabled: true),
        ]
        let band = makeSuggestedBand(existing: existing)
        XCTAssertEqual(band.frequency, 1000, accuracy: 10)
        XCTAssertEqual(band.filterType, .parametric)
        XCTAssertEqual(band.gain, 0)
    }

    func testEmptyListCentersAudibleRange() {
        let band = makeSuggestedBand(existing: [])
        // Midpoint of 20 Hz–20 kHz in log space is ~632 Hz.
        XCTAssertEqual(band.frequency, 632, accuracy: 10)
    }

    func testDenseLayoutPicksEdgeGap() {
        // 10-band ISO layout: adjacent bands are 1 octave apart, which is
        // wider than the edge gaps (20→31 Hz ≈ 0.63 oct, 16 k→20 k ≈ 0.32
        // oct), so the suggestion must land between two ISO centers.
        let band = makeSuggestedBand(existing: makeDefaultBands())
        XCTAssertGreaterThan(band.frequency, 31)
        XCTAssertLessThan(band.frequency, 16000)
        // Q should be clamped into a sane range.
        XCTAssertGreaterThanOrEqual(band.q, 0.5)
        XCTAssertLessThanOrEqual(band.q, 10)
    }
}

final class GraphRangeTests: XCTestCase {

    func testAutoRangePicksSmallestFit() {
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 0), 6)
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 4.9), 6)
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 5.5), 12)
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 11.5), 18)
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 17.5), 24)
        XCTAssertEqual(GraphRange.auto(forPeakAbsDB: 40), 24)
    }
}

final class EditHistoryTests: XCTestCase {

    func testUndoRedoBasic() {
        let h = EditHistory(initial: 0, coalesceInterval: 0)
        h.recordEdit(1)
        h.recordEdit(2)
        XCTAssertTrue(h.canUndo)
        XCTAssertEqual(h.undo(current: 2), 1)
        XCTAssertEqual(h.undo(current: 1), 0)
        XCTAssertNil(h.undo(current: 0))
        XCTAssertEqual(h.redo(current: 0), 1)
        XCTAssertEqual(h.redo(current: 1), 2)
        XCTAssertNil(h.redo(current: 2))
    }

    func testCoalescingCollapsesGesture() {
        let h = EditHistory(initial: 0, coalesceInterval: 0.5)
        let t0 = Date()
        // A drag: many edits in rapid succession → one undo step.
        h.recordEdit(1, at: t0)
        h.recordEdit(2, at: t0.addingTimeInterval(0.1))
        h.recordEdit(3, at: t0.addingTimeInterval(0.2))
        // New gesture after a pause.
        h.recordEdit(9, at: t0.addingTimeInterval(1.0))
        XCTAssertEqual(h.undo(current: 9), 3)
        XCTAssertEqual(h.undo(current: 3), 0)
        XCTAssertNil(h.undo(current: 0))
    }

    func testEditClearsRedo() {
        let h = EditHistory(initial: 0, coalesceInterval: 0)
        h.recordEdit(1)
        XCTAssertEqual(h.undo(current: 1), 0)
        XCTAssertTrue(h.canRedo)
        h.recordEdit(5)
        XCTAssertFalse(h.canRedo)
        XCTAssertEqual(h.undo(current: 5), 0)
    }

    func testNoOpEditNotRecorded() {
        let h = EditHistory(initial: 7, coalesceInterval: 0)
        h.recordEdit(7)
        XCTAssertFalse(h.canUndo)
    }

    func testLimitBoundsStack() {
        let h = EditHistory(initial: 0, coalesceInterval: 0, limit: 3)
        for i in 1...10 { h.recordEdit(i) }
        XCTAssertEqual(h.undoStack.count, 3)
    }
}

final class SpectrumTapTests: XCTestCase {

    func testFullScaleSineReadsZeroDB() {
        let sr = 48000.0
        let tap = SpectrumTap(sampleRate: sr)!
        // Exactly bin-centered frequency: bin 43 → 43·48000/2048 ≈ 1007.8 Hz.
        let f = 43.0 * sr / Double(tap.n)
        let frames = 4096
        var l = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            l[i] = sinf(Float(2.0 * .pi * f * Double(i) / sr))
        }
        l.withUnsafeBufferPointer { buf in
            tap.writePre(l: buf.baseAddress!, r: buf.baseAddress!, frames: frames)
            tap.writePost(l: buf.baseAddress!, r: buf.baseAddress!, frames: frames)
        }
        let freqs = FrequencyResponse.logFrequencies(count: 120)
        let (pre, post) = tap.analyze(frequencies: freqs)

        // The display bin nearest the sine frequency should read ~0 dBFS.
        let nearest = freqs.enumerated().min {
            abs($0.element - f) < abs($1.element - f)
        }!.offset
        XCTAssertEqual(pre[nearest], 0, accuracy: 1.0)
        XCTAssertEqual(post[nearest], 0, accuracy: 1.0)

        // Far away from the tone it should be near the floor.
        let farIdx = freqs.firstIndex { $0 > 10000 }!
        XCTAssertLessThan(pre[farIdx], -50)
    }

    func testSilenceReadsFloor() {
        let tap = SpectrumTap(sampleRate: 48000)!
        let silence = [Float](repeating: 0, count: 2048)
        silence.withUnsafeBufferPointer {
            tap.writePre(l: $0.baseAddress!, r: $0.baseAddress!, frames: 2048)
        }
        let freqs = FrequencyResponse.logFrequencies(count: 32)
        let (pre, _) = tap.analyze(frequencies: freqs)
        XCTAssertTrue(pre.allSatisfy { $0 <= SpectrumTap.floorDB + 0.001 })
    }

    func testReleaseSmoothingDecays() {
        let sr = 48000.0
        let tap = SpectrumTap(sampleRate: sr)!
        let f = 43.0 * sr / Double(tap.n)
        var tone = [Float](repeating: 0, count: 2048)
        for i in 0..<2048 { tone[i] = sinf(Float(2.0 * .pi * f * Double(i) / sr)) }
        let freqs = FrequencyResponse.logFrequencies(count: 120)
        tone.withUnsafeBufferPointer {
            tap.writePre(l: $0.baseAddress!, r: $0.baseAddress!, frames: 2048)
        }
        let loud = tap.analyze(frequencies: freqs).pre
        // Tone stops: buffer overwritten with silence.
        let silence = [Float](repeating: 0, count: 2048)
        silence.withUnsafeBufferPointer {
            tap.writePre(l: $0.baseAddress!, r: $0.baseAddress!, frames: 2048)
        }
        let decayed = tap.analyze(frequencies: freqs).pre
        let nearest = freqs.enumerated().min {
            abs($0.element - f) < abs($1.element - f)
        }!.offset
        // Release drops 3 dB per analyze call, not instantly.
        XCTAssertEqual(decayed[nearest], loud[nearest] - 3.0, accuracy: 0.01)
    }
}
