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

    // I2: a neutral write (gain snaps to 0, unmuted) for a bundleID with no
    // existing setting must record nothing — no entry, no grace deadline, no
    // exception, no persistence pin.
    func testFirstTouchNeutralCreatesNoException() {
        let m = AppMixer()
        m.setGain(0, for: "a")
        XCTAssertTrue(m.settings.isEmpty)
        XCTAssertNil(m.nextGraceDeadline(now: t0.addingTimeInterval(1000)))
        XCTAssertTrue(m.desiredExceptions(apps: [app("a")], now: t0).isEmpty)

        // A neutral MUTE toggle (unmute) on an untouched app is also a
        // first-touch neutral write and must be equally inert.
        let m2 = AppMixer()
        m2.setMuted(false, for: "b")
        XCTAssertTrue(m2.settings.isEmpty)
    }

    // A neutral write on an app with an EXISTING non-neutral setting must
    // keep today's behavior: the entry stays and grace arms.
    func testNeutralWriteOnExistingSettingStillArmsGrace() {
        let m = AppMixer()
        m.setGain(-12, for: "a")
        m.setGain(0, for: "a")
        XCTAssertNotNil(m.settings["a"])
        XCTAssertNotNil(m.nextGraceDeadline(now: Date()))
    }

    // I4: once a grace deadline expires, a neutral setting must be GC'd —
    // removed from settings (and graceDeadlines) so it stops pinning a dead
    // row and stops persisting forever.
    func testGraceExpiryRemovesNeutralSetting() {
        let key = "paraeq.appMixer"
        UserDefaults.standard.removeObject(forKey: key)
        let m = AppMixer(engine: nil, directory: nil)
        let base = Date()
        m.setGain(-12, for: "a")
        m.setGain(0, for: "a")
        XCTAssertNotNil(m.settings["a"])

        m.expireGrace(now: base.addingTimeInterval(AppMixer.graceSeconds + 6))

        XCTAssertNil(m.settings["a"])
        m.savePendingNow()
        let reloaded = AppMixer(engine: nil, directory: nil)
        XCTAssertNil(reloaded.settings["a"])
        UserDefaults.standard.removeObject(forKey: key)
    }

    // A re-adjustment during grace clears the deadline (existing behavior);
    // expireGrace must not touch that entry even once "expired" wall-clock
    // time has passed, since it's no longer neutral.
    func testGraceExpiryLeavesReadjustedSettingAlone() {
        let m = AppMixer()
        let base = Date()
        m.setGain(-12, for: "a")
        m.setGain(0, for: "a")
        m.setGain(-6, for: "a")   // re-adjust during grace: deadline cleared
        m.expireGrace(now: base.addingTimeInterval(AppMixer.graceSeconds + 6))
        XCTAssertEqual(m.settings["a"]?.gainDB, -6)
    }

    func testSettingCodableRoundTrip() throws {
        let s = AppMixerSetting(gainDB: -7.5, muted: true)
        let data = try JSONEncoder().encode(["com.x.y": s])
        let back = try JSONDecoder().decode([String: AppMixerSetting].self, from: data)
        XCTAssertEqual(back["com.x.y"], s)
    }
}

// MARK: - AppAudioDirectory grouping

final class AppDirectoryGroupingTests: XCTestCase {

    private typealias Snap = AppAudioDirectory.ProcessSnapshot

    /// Resolver mapping helper pids 100.. to app "parent"; others self-named.
    private func resolve(_ pid: pid_t, _ bundleID: String) -> (String, String)? {
        if pid >= 100 { return ("com.parent.app", "Parent") }
        if bundleID.isEmpty { return nil }
        return (bundleID, String(bundleID.split(separator: ".").last!))
    }

    func testGroupsHelpersUnderResponsibleApp() {
        let snaps = [
            Snap(objectID: 1, pid: 100, bundleID: "com.parent.helper.renderer",
                 isRunningOutput: true),
            Snap(objectID: 2, pid: 101, bundleID: "com.parent.helper.gpu",
                 isRunningOutput: false),
            Snap(objectID: 3, pid: 7, bundleID: "com.solo.app", isRunningOutput: false),
        ]
        let apps = AppAudioDirectory.group(snaps, resolve: resolve)
        XCTAssertEqual(apps.count, 2)
        let parent = apps.first { $0.bundleID == "com.parent.app" }!
        XCTAssertEqual(Set(parent.objectIDs), [1, 2])
        XCTAssertTrue(parent.isPlaying)          // any member playing → playing
        let solo = apps.first { $0.bundleID == "com.solo.app" }!
        XCTAssertEqual(solo.objectIDs, [3])
        XCTAssertFalse(solo.isPlaying)
    }

    func testUnresolvableProcessesAreDropped() {
        let snaps = [Snap(objectID: 9, pid: 5, bundleID: "", isRunningOutput: true)]
        XCTAssertTrue(AppAudioDirectory.group(snaps, resolve: resolve).isEmpty)
    }

    func testSortPlayingFirstThenName() {
        let snaps = [
            Snap(objectID: 1, pid: 1, bundleID: "com.b.zeta", isRunningOutput: false),
            Snap(objectID: 2, pid: 2, bundleID: "com.a.alpha", isRunningOutput: false),
            Snap(objectID: 3, pid: 3, bundleID: "com.c.mid", isRunningOutput: true),
        ]
        let apps = AppAudioDirectory.group(snaps, resolve: resolve)
        XCTAssertEqual(apps.map(\.bundleID),
                       ["com.c.mid", "com.a.alpha", "com.b.zeta"])
    }

    func testObjectIDsSortedForStableEquality() {
        let a = AppAudioDirectory.group(
            [Snap(objectID: 5, pid: 100, bundleID: "x", isRunningOutput: false),
             Snap(objectID: 3, pid: 101, bundleID: "y", isRunningOutput: false)],
            resolve: resolve)
        let b = AppAudioDirectory.group(
            [Snap(objectID: 3, pid: 101, bundleID: "y", isRunningOutput: false),
             Snap(objectID: 5, pid: 100, bundleID: "x", isRunningOutput: false)],
            resolve: resolve)
        XCTAssertEqual(a, b)   // order of discovery must not change identity
    }
}

// MARK: - AppMixer wiring (persistence + display list)

final class AppMixerWiringTests: XCTestCase {

    private let key = "paraeq.appMixer"
    override func setUp() { UserDefaults.standard.removeObject(forKey: key) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key) }

    func testSettingsPersistAndReload() {
        let m = AppMixer(engine: nil, directory: nil)
        m.setGain(-9, for: "com.apple.Music")
        m.setMuted(true, for: "com.spotify.client")
        m.savePendingNow()
        let m2 = AppMixer(engine: nil, directory: nil)
        XCTAssertEqual(m2.setting(for: "com.apple.Music").gainDB, -9)
        XCTAssertTrue(m2.setting(for: "com.spotify.client").muted)
    }

    func testResetRemovesFromPersistence() {
        let m = AppMixer(engine: nil, directory: nil)
        m.setGain(-9, for: "a")
        m.reset("a")
        m.savePendingNow()
        XCTAssertTrue(AppMixer(engine: nil, directory: nil).settings.isEmpty)
    }

    func testDisplayAppsIncludesPinnedNotRunning() {
        let m = AppMixer(engine: nil, directory: nil)
        m.setGain(-9, for: "com.gone.app")
        let rows = m.displayApps
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "com.gone.app")
        XCTAssertFalse(rows[0].isPlaying)
        XCTAssertTrue(rows[0].objectIDs.isEmpty)   // pinned placeholder
    }

    func testDisplayAppsExcludesNonPlayingUnadjustedApp() {
        let m = AppMixer(engine: nil, directory: nil)
        let silent = AudioApp(bundleID: "com.silent.app", name: "silent",
                               objectIDs: [42], isPlaying: false)
        let rows = m.displayApps(from: [silent])
        XCTAssertTrue(rows.isEmpty)
    }

    func testDisplayAppsIncludesPlayingApp() {
        let m = AppMixer(engine: nil, directory: nil)
        let playing = AudioApp(bundleID: "com.playing.app", name: "playing",
                                objectIDs: [7], isPlaying: true)
        let rows = m.displayApps(from: [playing])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "com.playing.app")
    }

    func testDisplayAppsIncludesNonPlayingAdjustedAppWithRealObjectIDs() {
        let m = AppMixer(engine: nil, directory: nil)
        m.setGain(-9, for: "com.adjusted.app")
        let silentAdjusted = AudioApp(bundleID: "com.adjusted.app", name: "adjusted",
                                       objectIDs: [11, 12], isPlaying: false)
        let rows = m.displayApps(from: [silentAdjusted])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "com.adjusted.app")
        XCTAssertEqual(rows[0].objectIDs, [11, 12])
        XCTAssertFalse(rows[0].isPlaying)
    }
}

// MARK: - Directory -> mixer resync (post-relaunch re-arm bug)

/// AppAudioDirectory is HAL-backed (start() registers real CoreAudio
/// listeners and queues a real refresh), so it can't be fully faked out in
/// a unit test. These tests exercise what IS testable without audio
/// hardware or a live tap: (1) the directory really does invoke `onChange`
/// on the main thread from its first refresh after `start()` — this is the
/// actual bug fix, so it's worth paying for a real (if slow-ish) HAL round
/// trip rather than only asserting the property holds a value; and (2)
/// AppMixer's convenience init wires `onChange` before calling `start()`,
/// so a directory constructed alongside an AppMixer is never left silently
/// unobserved. Full "persisted exception re-arms after relaunch" coverage
/// needs a live process tap and is done via manual/log verification (see
/// task report), not here.
final class AppAudioDirectoryResyncTests: XCTestCase {

    /// RED (pre-fix) reasoning: before this change, AppAudioDirectory had no
    /// `onChange` property at all, so this test would fail to compile —
    /// the strongest possible RED signal for "the contract doesn't exist
    /// yet". Post-fix, start()'s first debounced refresh must call
    /// `onChange` on the main thread once it publishes.
    func testOnChangeFiresOnFirstRefreshAfterStart() {
        let directory = AppAudioDirectory()
        let fired = expectation(description: "onChange fired on first refresh")
        directory.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        directory.start()
        wait(for: [fired], timeout: 3.0)
    }

    /// AppMixer's convenience init must set `directory.onChange` before
    /// calling `directory.start()` — verified two ways: the closure is
    /// non-nil immediately after init (so nothing between start() and
    /// wiring could have slipped through unobserved), and the directory's
    /// own first refresh (kicked by that same start() call) reaches
    /// AppMixer's appsChanged() end-to-end, proving the wiring is live and
    /// not just assigned-and-ignored.
    func testAppMixerWiresOnChangeBeforeStartingDirectory() {
        UserDefaults.standard.removeObject(forKey: "paraeq.appMixer")
        let directory = AppAudioDirectory()
        let mixer = AppMixer(engine: nil, directory: directory)
        XCTAssertNotNil(directory.onChange)

        let fired = expectation(description: "directory refresh reached AppMixer")
        // Wrap the already-installed callback so we observe the real
        // end-to-end path (directory refresh -> AppMixer.appsChanged())
        // rather than replacing it with a test-only stand-in.
        let installed = directory.onChange
        directory.onChange = {
            installed?()
            fired.fulfill()
        }
        wait(for: [fired], timeout: 3.0)
        _ = mixer   // keep alive for the duration of the async refresh
    }
}
