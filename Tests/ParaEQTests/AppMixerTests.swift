import XCTest
import CoreAudio

@testable import ParaEQ

// MARK: - InputStaging (multi-stream stage & mix)

final class InputStagingTests: XCTestCase {

    /// Builds an AudioBufferList with the given buffers (channels, samples).
    /// Samples are interleaved when channels > 1 and frames*channels == count.
    private func withABL(
        _ buffers: [(channels: Int, samples: [Float])],
        _ body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) {
        let ablMem = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(ablMem.unsafeMutablePointer) }
        var stores: [UnsafeMutablePointer<Float>] = []
        defer { stores.forEach { $0.deallocate() } }
        for (i, buf) in buffers.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: buf.samples.count)
            p.update(from: buf.samples, count: buf.samples.count)
            stores.append(p)
            ablMem[i] = AudioBuffer(
                mNumberChannels: UInt32(buf.channels),
                mDataByteSize: UInt32(buf.samples.count * 4),
                mData: UnsafeMutableRawPointer(p))
        }
        body(ablMem)
    }

    private func runStage(
        _ buffers: [(channels: Int, samples: [Float])],
        gains: [Float] = [],
        maxFrames: Int = 64
    ) -> (l: [Float], r: [Float], frames: Int) {
        let sl = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        let sr = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        defer { sl.deallocate(); sr.deallocate() }
        sl.initialize(repeating: -99, count: maxFrames)   // poison: must be overwritten
        sr.initialize(repeating: -99, count: maxFrames)
        var g = gains + [Float](repeating: 0, count: 16 - gains.count)
        var frames = 0
        withABL(buffers) { abl in
            frames = InputStaging.stage(
                inABL: abl, stageL: sl, stageR: sr, appGains: &g, maxFrames: maxFrames)
        }
        return (Array(UnsafeBufferPointer(start: sl, count: frames)),
                Array(UnsafeBufferPointer(start: sr, count: frames)), frames)
    }

    func testSingleInterleavedStereoBuffer() {
        // 4 frames interleaved LRLR — matches today's single-tap path.
        let r = runStage([(2, [1, 10, 2, 20, 3, 30, 4, 40])])
        XCTAssertEqual(r.frames, 4)
        XCTAssertEqual(r.l, [1, 2, 3, 4])
        XCTAssertEqual(r.r, [10, 20, 30, 40])
    }

    func testSinglePlanarPair() {
        let r = runStage([(1, [1, 2, 3]), (1, [10, 20, 30])])
        XCTAssertEqual(r.frames, 3)
        XCTAssertEqual(r.l, [1, 2, 3])
        XCTAssertEqual(r.r, [10, 20, 30])
    }

    func testMonoDuplicatesToBothChannels() {
        let r = runStage([(1, [5, 6, 7])])
        XCTAssertEqual(r.l, [5, 6, 7])
        XCTAssertEqual(r.r, [5, 6, 7])
    }

    func testExceptionPairMixedAtGain() {
        // Global interleaved pair + one exception interleaved pair at gain 0.5.
        let r = runStage(
            [(2, [1, 1, 1, 1]), (2, [4, 8, 4, 8])],
            gains: [0.5])
        XCTAssertEqual(r.frames, 2)
        XCTAssertEqual(r.l, [1 + 2 as Float, 1 + 2 as Float])     // 1 + 0.5*4
        XCTAssertEqual(r.r, [1 + 4 as Float, 1 + 4 as Float])     // 1 + 0.5*8
    }

    func testTwoExceptionsPlanarDifferentGains() {
        // Global planar + two exception planar pairs, gains 1.0 and 0.25.
        let r = runStage(
            [(1, [1, 1]), (1, [1, 1]),          // global L, R
             (1, [10, 10]), (1, [20, 20]),      // exc 0 L, R
             (1, [40, 40]), (1, [80, 80])],     // exc 1 L, R
            gains: [1.0, 0.25])
        XCTAssertEqual(r.l, [1 + 10 + 10 as Float, 1 + 10 + 10 as Float])
        XCTAssertEqual(r.r, [1 + 20 + 20 as Float, 1 + 20 + 20 as Float])
    }

    func testMutedExceptionContributesNothing() {
        let r = runStage(
            [(2, [1, 1, 1, 1]), (2, [9, 9, 9, 9])],
            gains: [0])
        XCTAssertEqual(r.l, [1, 1])
        XCTAssertEqual(r.r, [1, 1])
    }

    func testFramesClampedToMaxFrames() {
        let big = [Float](repeating: 1, count: 200)   // 100 frames interleaved
        let r = runStage([(2, big)], maxFrames: 64)
        XCTAssertEqual(r.frames, 64)
    }

    func testShorterExceptionBufferOnlyMixesItsFrames() {
        // Exception has 1 frame vs global's 2 — only frame 0 gets the add.
        let r = runStage(
            [(2, [1, 1, 1, 1]), (2, [5, 5])],
            gains: [1.0])
        XCTAssertEqual(r.frames, 2)
        XCTAssertEqual(r.l, [6, 1])
        XCTAssertEqual(r.r, [6, 1])
    }
}
