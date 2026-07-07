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

    func testPairsBeyondSlot16AreIgnored() {
        // Global interleaved pair + 17 exception interleaved pairs.
        // The bounds guard (pair - 1 < 16) should skip the 17th pair.
        var buffers: [(channels: Int, samples: [Float])] = []
        buffers.append((2, [10, 10, 10, 10]))  // global
        for _ in 0..<16 {
            buffers.append((2, [1, 1, 1, 1]))  // exceptions 0–15, each gain 1.0
        }
        buffers.append((2, [99, 99, 99, 99]))  // exception 16 (should be skipped)

        let r = runStage(buffers, gains: [Float](repeating: 1.0, count: 16))
        XCTAssertEqual(r.frames, 2)
        // Result: global [10,10] + first 16 exceptions each [1,1] = [26,26].
        // Exception 17 with [99,99] is not mixed due to bounds guard.
        XCTAssertEqual(r.l, [26, 26])
        XCTAssertEqual(r.r, [26, 26])
    }
}

// MARK: - AppMixer policy

final class AppMixerPolicyTests: XCTestCase {

    // Wall-clock base: AppMixer stamps grace deadlines with Date(), so the
    // test's reference time must be the real clock, not a fixed epoch.
    private let t0 = Date()
    private func app(_ id: String, objects: [AudioObjectID] = [42],
                     playing: Bool = true) -> AudioApp {
        AudioApp(bundleID: id, name: id, objectIDs: objects, isPlaying: playing)
    }

    func testSettingDefaults() {
        let s = AppMixerSetting()
        XCTAssertTrue(s.isNeutral)
        XCTAssertEqual(s.linearGain, 1.0, accuracy: 1e-6)
    }

    func testLinearGainMath() {
        XCTAssertEqual(AppMixerSetting(gainDB: -6).linearGain, 0.501, accuracy: 0.001)
        XCTAssertEqual(AppMixerSetting(gainDB: 6).linearGain, 1.995, accuracy: 0.001)
        XCTAssertEqual(AppMixerSetting(gainDB: -60).linearGain, 0)      // -inf zone
        XCTAssertEqual(AppMixerSetting(gainDB: 0, muted: true).linearGain, 0)
        XCTAssertFalse(AppMixerSetting(gainDB: 0, muted: true).isNeutral)
        XCTAssertFalse(AppMixerSetting(gainDB: -3).isNeutral)
    }

    func testNeutralAppNeedsNoException() {
        let m = AppMixer()
        XCTAssertTrue(m.desiredExceptions(apps: [app("a")], now: t0).isEmpty)
    }

    func testAdjustedRunningAppGetsException() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        let ex = m.desiredExceptions(apps: [app("a", objects: [7, 8])], now: t0)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].bundleID, "a")
        XCTAssertEqual(ex[0].objectIDs, [7, 8])
        XCTAssertEqual(ex[0].gainLinear, AppMixerSetting(gainDB: -12).linearGain)
    }

    func testAdjustedButNotRunningAppGetsNoException() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        XCTAssertTrue(m.desiredExceptions(apps: [], now: t0).isEmpty)
    }

    func testMutedAppGetsExceptionWithZeroGain() {
        let m = AppMixer()
        m.setMuted(true, for: "a")
        let ex = m.desiredExceptions(apps: [app("a")], now: t0)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].gainLinear, 0)
    }

    func testReturnToNeutralKeepsExceptionDuringGrace() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        _ = m.desiredExceptions(apps: [app("a")], now: t0)
        m.setGain(0, for: "a")
        // Within grace: exception survives at unity gain.
        let during = m.desiredExceptions(apps: [app("a")], now: t0.addingTimeInterval(5))
        XCTAssertEqual(during.count, 1)
        XCTAssertEqual(during[0].gainLinear, 1.0, accuracy: 1e-6)
        // After grace: gone.
        let after = m.desiredExceptions(
            apps: [app("a")], now: t0.addingTimeInterval(AppMixer.graceSeconds + 6))
        XCTAssertTrue(after.isEmpty)
    }

    func testReAdjustDuringGraceCancelsIt() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        _ = m.desiredExceptions(apps: [app("a")], now: t0)
        m.setGain(0, for: "a")
        m.setGain(-6, for: "a")   // wiggle back
        let ex = m.desiredExceptions(
            apps: [app("a")], now: t0.addingTimeInterval(AppMixer.graceSeconds + 6))
        XCTAssertEqual(ex.count, 1)
        XCTAssertNil(m.nextGraceDeadline(now: t0))
    }

    func testNextGraceDeadlineReported() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        _ = m.desiredExceptions(apps: [app("a")], now: t0)
        m.setGain(0, for: "a")
        let d = m.nextGraceDeadline(now: t0)
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.timeIntervalSince(t0), AppMixer.graceSeconds, accuracy: 1.0)
    }

    func testResetRemovesSettingImmediately() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        m.reset("a")
        XCTAssertTrue(m.desiredExceptions(apps: [app("a")], now: t0).isEmpty)
        XCTAssertTrue(m.settings.isEmpty)
    }

    func testSlotCapEnforced() {
        let m = AppMixer()
        for i in 0..<20 { m.setGain(-3, for: "app\(i)") }
        let apps = (0..<20).map { app("app\($0)", objects: [AudioObjectID($0 + 100)]) }
        let ex = m.desiredExceptions(apps: apps, now: t0)
        XCTAssertEqual(ex.count, AppMixer.maxExceptions)
    }

    func testSlotsFullReflectsNonNeutralCount() {
        let m = AppMixer()
        XCTAssertFalse(m.slotsFull)
        for i in 0..<AppMixer.maxExceptions { m.setGain(-3, for: "app\(i)") }
        XCTAssertTrue(m.slotsFull)
    }

    func testExceptionsOrderIsStableAcrossGainChanges() {
        // Engine restarts only when the (bundleID, objectIDs) list changes,
        // so order must not depend on gain values.
        let m = AppMixer()
        m.setGain(-3, for: "b")
        m.setGain(-3, for: "a")
        let apps = [app("a", objects: [1]), app("b", objects: [2])]
        let before = m.desiredExceptions(apps: apps, now: t0).map(\.bundleID)
        m.setGain(-9, for: "a")
        let after = m.desiredExceptions(apps: apps, now: t0).map(\.bundleID)
        XCTAssertEqual(before, after)
    }

    func testFreshAdjustmentPreemptsGraceHoldoverAtCap() {
        let m = AppMixer()
        for i in 0..<15 { m.setGain(-3, for: "app\(i)") }
        // "old" is adjusted then returned to neutral, becoming a grace
        // holdover that would otherwise occupy the 16th slot.
        m.setGain(-3, for: "old")
        _ = m.desiredExceptions(apps: [app("old")], now: t0)
        m.setGain(0, for: "old")
        // Fresh 16th adjustment, last in adjustOrder.
        m.setGain(-3, for: "fresh")

        var apps = (0..<15).map { app("app\($0)") }
        apps.append(app("old"))
        apps.append(app("fresh"))

        let ex = m.desiredExceptions(apps: apps, now: t0.addingTimeInterval(5))
        let ids = Set(ex.map(\.bundleID))
        XCTAssertTrue(ids.contains("fresh"))
        XCTAssertFalse(ids.contains("old"))
        XCTAssertEqual(ex.count, AppMixer.maxExceptions)
    }

    func testNeutralTransitionUnderCapKeepsOrder() {
        // a, b, c adjusted non-neutral in that order, well under the cap.
        let m = AppMixer()
        m.setGain(-3, for: "a")
        m.setGain(-3, for: "b")
        m.setGain(-3, for: "c")
        let apps = [app("a"), app("b"), app("c")]
        let before = m.desiredExceptions(apps: apps, now: t0).map(\.bundleID)
        XCTAssertEqual(before, ["a", "b", "c"])

        // "a" returns to neutral (enters grace) while b, c remain adjusted.
        m.setGain(0, for: "a")
        let during = m.desiredExceptions(apps: apps, now: t0.addingTimeInterval(5))
        // Membership is unchanged (a is still present via grace holdover);
        // order must remain first-adjustment order, not move "a" to the tail.
        XCTAssertEqual(during.map(\.bundleID), ["a", "b", "c"])
    }

    func testSettingCodableRoundTrip() throws {
        let s = AppMixerSetting(gainDB: -7.5, muted: true)
        let data = try JSONEncoder().encode(["com.x.y": s])
        let back = try JSONDecoder().decode([String: AppMixerSetting].self, from: data)
        XCTAssertEqual(back["com.x.y"], s)
    }
}
