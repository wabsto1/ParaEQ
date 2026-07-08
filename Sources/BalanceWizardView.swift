import SwiftUI
import AppKit

/// Hands-free auto-advance decision, pure for testability: a measurement
/// starts only while prompting, with no capture in flight, once the seal
/// gate is stable and the post-trial re-seat gap has fully elapsed.
enum AutoAdvance {
    static func shouldStart(prompting: Bool, busy: Bool,
                            sealStable: Bool, gapTicksRemaining: Int) -> Bool {
        prompting && !busy && sealStable && gapTicksRemaining == 0
    }
}

// MARK: - Balance-calibration wizard
//
// Guides a per-ear level measurement: the multitone stimulus plays on one
// channel while the user holds that earcup against the Mac's microphone.
// Accuracy machinery, in the order it attacks the error budget:
//  * seal gate — Measure only arms once the tone level has been stable,
//    so every take starts from comparable coupling;
//  * 3 re-seated trials per ear, grouped L,L,L,R,R,R (one ear-swap per
//    run; re-seating spread dominates any slow drift at this timescale);
//  * per-trial levels are per-tone medians across 0.5 s blocks (a bump
//    mid-capture can't drag the level);
//  * per-tone medians across trials, then the median of per-tone L−R
//    deltas (a seating that kills one tone can't skew the result).
// The mic and coupling cancel in the L−R comparison, so an uncalibrated
// built-in mic is sufficient for level matching.

@Observable
@MainActor
final class BalanceWizard {
    enum Side: String, Equatable { case left = "LEFT", right = "RIGHT" }
    enum Phase: Equatable {
        /// Waiting for the user to (re-)seat the cup for trial N (1-based).
        case prompt(Side, trial: Int)
        case measuring(Side, trial: Int)
        case done
        case failed(String)
    }
    enum SealStatus: Equatable {
        case noSignal      // tone not reaching the mic yet
        case unstable      // level still moving — keep settling
        case stable        // armed
    }

    private(set) var phase: Phase = .prompt(.left, trial: 1)
    /// Live mic RMS — read ONLY by the MicLevelBar leaf view (30 fps rule).
    private(set) var micLevel: Float = 0
    /// Capture progress 0…1 while measuring.
    private(set) var progress: Double = 0
    /// Per-trial per-tone levels (dB), one row per completed re-seated trial.
    private(set) var leftTrialTones: [[Double]] = []
    private(set) var rightTrialTones: [[Double]] = []
    private(set) var warning: String?
    private(set) var micName = ""
    private(set) var applied = false
    /// Seal gate state (~4 Hz updates while prompting).
    private(set) var sealStatus: SealStatus = .noSignal
    /// Whole seconds left in the post-trial re-seat gap (0 = gap over).
    /// Updated at most once per second so body reads stay cheap.
    private(set) var gapSecondsShown = 0

    private let engine: AudioEngine
    private var mic: MicCapture?
    private var levelTimer: Timer?
    private var task: Task<Void, Never>?
    private var levelTicks = 0
    private var sealHistory: [Double] = []
    /// 30 fps ticks left before auto-start may arm again (re-seat time).
    @ObservationIgnored private var gapTicksRemaining = 0
    /// Per-tone ambient captured once per session, before any stimulus.
    private var ambientToneDBs: [Double] = []
    private var ambientDB = BalanceCalibration.floorDB
    private var ambientReady = false

    static let captureSeconds = 3.0
    /// Hands-free: hold-off after each capture before the next can auto-start,
    /// so there's always time to lift and re-seat (or swap ears) the cup.
    static let reseatGapSeconds = 5.0
    /// Re-seated measurements per ear; the average beats any single seating.
    static let trialsPerSide = 3
    /// Stimulus must clear the ambient tone-bin level by this much.
    static let minSNRdB = 15.0
    /// Seal gate: last readings must agree within this to arm Measure.
    static let sealWindowDB = 1.0

    init(engine: AudioEngine) {
        self.engine = engine
    }

    // MARK: Derived results

    /// Per-trial broadband level (median of tones) — badges and spread.
    var leftTrials: [Double] { leftTrialTones.map(BalanceCalibration.median) }
    var rightTrials: [Double] { rightTrialTones.map(BalanceCalibration.median) }

    var leftStats: (meanDB: Double, stdDB: Double)? {
        leftTrialTones.count == Self.trialsPerSide
            ? BalanceCalibration.trialStats(leftTrials) : nil
    }

    var rightStats: (meanDB: Double, stdDB: Double)? {
        rightTrialTones.count == Self.trialsPerSide
            ? BalanceCalibration.trialStats(rightTrials) : nil
    }

    /// Median of per-tone L−R deltas, each tone first median'd across trials.
    var deltaDB: Double? {
        guard leftTrialTones.count == Self.trialsPerSide,
              rightTrialTones.count == Self.trialsPerSide else { return nil }
        let toneCount = MultiTone.frequencies.count
        let l = (0..<toneCount).map { i in
            BalanceCalibration.median(leftTrialTones.map { $0[i] })
        }
        let r = (0..<toneCount).map { i in
            BalanceCalibration.median(rightTrialTones.map { $0[i] })
        }
        return BalanceCalibration.medianToneDelta(left: l, right: r)
    }

    var result: (deltaDB: Double, balance: Float)? {
        deltaDB.map { BalanceCalibration.recommendation(deltaDB: $0) }
    }

    /// Worst per-side trial-to-trial spread — the repeatability the user
    /// should judge the result by (re-seating dominates the error budget).
    var spreadDB: Double {
        max(leftStats?.stdDB ?? 0, rightStats?.stdDB ?? 0)
    }

    // MARK: Session lifecycle

    func begin() {
        guard mic == nil else { return }
        // Window scenes keep the view alive across close/reopen — start fresh.
        phase = .prompt(.left, trial: 1)
        leftTrialTones = []
        rightTrialTones = []
        warning = nil
        applied = false
        progress = 0
        sealStatus = .noSignal
        sealHistory = []
        gapTicksRemaining = 0
        gapSecondsShown = 0
        ambientReady = false
        guard engine.isRunning else {
            phase = .failed("Start the equalizer first — the test tone plays through it.")
            return
        }
        guard let m = MicCapture() else {
            phase = .failed("No microphone available.")
            return
        }
        do {
            try m.start()   // first start triggers the mic permission prompt
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        mic = m
        micName = m.deviceName
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                          repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.levelTick() }
        }
        // Ambient reference (per tone) once per session, before any tone —
        // then keep the stimulus running through prompts so the seal gate
        // has a signal to judge.
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, let mic = self.mic else { return }
            let ambient = mic.snapshot(seconds: 1.0)
            self.ambientToneDBs = BalanceCalibration.toneLevelsDB(
                ambient, sampleRate: mic.sampleRate)
            self.ambientDB = BalanceCalibration.tonePowerDB(
                ambient, sampleRate: mic.sampleRate)
            self.ambientReady = true
            self.updateStimulus()
            self.task = nil
        }
    }

    /// Always safe to call; the window's onDisappear must call it.
    func stop() {
        task?.cancel()
        task = nil
        engine.setMeasureChannel(.off)
        levelTimer?.invalidate()
        levelTimer = nil
        mic?.stop()
        mic = nil
    }

    // MARK: Actions

    func measureCurrentSide() {
        guard case .prompt(let side, let trial) = phase, task == nil,
              sealStatus == .stable else { return }
        warning = nil
        task = Task { [weak self] in
            await self?.measure(side, trial: trial)
            self?.task = nil
        }
    }

    func redoSide(_ side: Side) {
        guard task == nil else { return }
        if side == .left { leftTrialTones = [] } else { rightTrialTones = [] }
        applied = false
        advance()
        // Same-side repeats keep the cup in place — force a re-seat pause.
        startReseatGap()
    }

    func apply() {
        guard let result else { return }
        engine.setBalance(result.balance)
        applied = true
    }

    // MARK: Internals

    /// Grouped order: L1, L2, L3, R1, R2, R3 — one ear finishes before the
    /// swap, so the cup only changes ears once per run. (Interleaving would
    /// cancel slow drift slightly better, but over a ~40 s run the drift is
    /// far below the re-seating spread; ergonomics wins.)
    private func advance() {
        if leftTrialTones.count < Self.trialsPerSide {
            phase = .prompt(.left, trial: leftTrialTones.count + 1)
        } else if rightTrialTones.count < Self.trialsPerSide {
            phase = .prompt(.right, trial: rightTrialTones.count + 1)
        } else {
            phase = .done
        }
        sealHistory = []
        sealStatus = .noSignal
        updateStimulus()
    }

    /// The stimulus stays on the prompted side (seal gate needs signal);
    /// off once done/failed, and always off before the ambient capture.
    private func updateStimulus() {
        guard ambientReady else { return }
        switch phase {
        case .prompt(let side, _), .measuring(let side, _):
            engine.setMeasureChannel(side == .left ? .left : .right)
        case .done, .failed:
            engine.setMeasureChannel(.off)
        }
    }

    /// 30 fps: mic meter + re-seat gap countdown; every 8th tick (~4 Hz):
    /// seal-gate evaluation and the hands-free auto-start decision.
    private func levelTick() {
        micLevel = mic?.level() ?? 0
        levelTicks += 1
        if gapTicksRemaining > 0 {
            gapTicksRemaining -= 1
            let secs = (gapTicksRemaining + 29) / 30
            if secs != gapSecondsShown { gapSecondsShown = secs }
        }
        guard levelTicks % 8 == 0, ambientReady,
              case .prompt = phase, task == nil, let mic else { return }
        let toneDB = BalanceCalibration.tonePowerDB(
            mic.snapshot(seconds: 0.4), sampleRate: mic.sampleRate)
        guard toneDB > ambientDB + Self.minSNRdB else {
            sealStatus = .noSignal
            sealHistory = []
            return
        }
        sealHistory.append(toneDB)
        if sealHistory.count > 4 { sealHistory.removeFirst() }
        sealStatus = sealHistory.count == 4
            && (sealHistory.max()! - sealHistory.min()!) < Self.sealWindowDB
            ? .stable : .unstable
        if AutoAdvance.shouldStart(prompting: true, busy: false,
                                   sealStable: sealStatus == .stable,
                                   gapTicksRemaining: gapTicksRemaining) {
            measureCurrentSide()
        }
    }

    /// Arm the post-capture hold-off and cue the user to re-seat.
    private func startReseatGap() {
        gapTicksRemaining = Int(Self.reseatGapSeconds * 30)
        gapSecondsShown = Int(Self.reseatGapSeconds)
        NSSound.beep()   // "lift and re-seat now" — fires only inside the gap
    }

    private func measure(_ side: Side, trial: Int) async {
        guard let mic else { return }
        phase = .measuring(side, trial: trial)
        progress = 0
        updateStimulus()

        do {
            let steps = 30
            for i in 1...steps {
                try await Task.sleep(for: .seconds(Self.captureSeconds / Double(steps)))
                progress = Double(i) / Double(steps)
            }
        } catch {
            return   // cancelled (window closed) — stop() turns the tone off
        }

        let samples = mic.snapshot(seconds: Self.captureSeconds)
        let rawDB = BalanceCalibration.tonePowerDB(samples, sampleRate: mic.sampleRate)

        guard rawDB > ambientDB + Self.minSNRdB else {
            warning = "Test tone not detected clearly (\(fmt(rawDB - ambientDB)) dB above "
                + "ambient at the tone frequencies; need \(Int(Self.minSNRdB))). Seal the "
                + "earcup flat over the mic and check the volume isn't muted."
            EngineLog.log(String(format:
                "calibration: %@ trial %d SNR fail — tones %.1f dB, ambient %.1f dB",
                side.rawValue, trial, rawDB, ambientDB))
            phase = .prompt(side, trial: trial)
            sealHistory = []
            sealStatus = .noSignal
            startReseatGap()
            return
        }

        let toneDBs = BalanceCalibration.robustToneLevels(
            samples, sampleRate: mic.sampleRate, ambientToneDBs: ambientToneDBs)
        EngineLog.log(String(format:
            "calibration: %@ trial %d/%d: %.2f dB (median of tones), ambient %.1f dB",
            side.rawValue, trial, Self.trialsPerSide,
            BalanceCalibration.median(toneDBs), ambientDB))

        if side == .left { leftTrialTones.append(toneDBs) }
        else { rightTrialTones.append(toneDBs) }
        advance()
        if case .prompt = phase { startReseatGap() }

        if phase == .done, let l = leftStats, let r = rightStats, let d = deltaDB {
            EngineLog.log(String(format:
                "calibration: result L %.2f dB (±%.2f) vs R %.2f dB (±%.2f), median tone delta %+.2f dB",
                l.meanDB, l.stdDB, r.meanDB, r.stdDB, d))
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}

// MARK: - Window UI

struct BalanceWizardView: View {
    let engine: AudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var wizard: BalanceWizard

    init(engine: AudioEngine) {
        self.engine = engine
        _wizard = State(initialValue: BalanceWizard(engine: engine))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Headphone Balance Calibration")
                .font(.headline)

            switch wizard.phase {
            case .prompt(let side, let trial):
                promptView(side, trial: trial)
            case .measuring(let side, let trial):
                measuringView(side, trial: trial)
            case .done:
                resultView
            case .failed(let message):
                failedView(message)
            }

            Spacer(minLength: 0)

            HStack {
                sideBadge("L", trials: wizard.leftTrials, stats: wizard.leftStats)
                sideBadge("R", trials: wizard.rightTrials, stats: wizard.rightStats)
                Spacer()
                Button(wizard.phase == .done ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 360, height: 400)
        .onAppear { wizard.begin() }
        .onDisappear { wizard.stop() }
    }

    private func promptView(_ side: BalanceWizard.Side, trial: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: side == .left ? "l.circle" : "r.circle")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("\(side.rawValue) — measurement \(trial) of \(BalanceWizard.trialsPerSide)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(trial == 1
                 ? "Hold the **\(side.rawValue)** earcup flat against the microphone (\(wizard.micName)). Best: laptop flat, cup resting under its own weight rather than hand-held."
                 : "Lift the **\(side.rawValue)** earcup and re-seat it in a slightly different position — the trials get averaged, which cancels placement luck.")
                .font(.callout)
                .multilineTextAlignment(.center)
            if let warning = wizard.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            MicLevelBar(wizard: wizard)
            if wizard.gapSecondsShown > 0 {
                Text("Lift and re-seat — next measurement arms in \(wizard.gapSecondsShown) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                sealStatusLine
            }
        }
    }

    private var sealStatusLine: some View {
        let (text, color): (String, Color) = switch wizard.sealStatus {
        case .noSignal: ("Waiting for the tone… seat the cup over the mic", .secondary)
        case .unstable: ("Signal found — hold still, measuring starts by itself", .orange)
        case .stable: ("Seal stable — measuring…", .green)
        }
        return Text(text).font(.caption).foregroundStyle(color)
    }

    private func measuringView(_ side: BalanceWizard.Side, trial: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Measuring \(side.rawValue) (\(trial)/\(BalanceWizard.trialsPerSide)) — hold still…")
                .font(.callout)
            MicLevelBar(wizard: wizard)
            ProgressView(value: wizard.progress)
        }
    }

    private var resultView: some View {
        VStack(spacing: 10) {
            if let r = wizard.result {
                if abs(r.deltaDB) < 0.25 {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text("Balanced within measurement limits (Δ \(String(format: "%+.2f", r.deltaDB)) dB). No correction needed.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                } else {
                    Text(String(format: "%@ side is %.2f dB quieter",
                                r.deltaDB > 0 ? "Right" : "Left", abs(r.deltaDB)))
                        .font(.callout.weight(.semibold))
                    Text(String(format: "Seating-to-seating spread ±%.2f dB%@",
                                wizard.spreadDB,
                                wizard.spreadDB > 0.5
                                    ? " — high; consider redoing that side"
                                    : ""))
                        .font(.caption)
                        .foregroundStyle(wizard.spreadDB > 0.5 ? .orange : .secondary)
                    if abs(r.deltaDB) >= 1.0 {
                        Text("Tip: with detachable cables, swap L/R cables and re-run — if the quiet side follows the cable, replace the cable instead of compensating.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button(wizard.applied
                           ? "Applied ✓"
                           : "Apply balance \(BalanceEntry.label(for: wizard.result?.balance ?? 0))") {
                        wizard.apply()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizard.applied)
                }
                HStack {
                    Button("Redo L") { wizard.redoSide(.left) }
                    Button("Redo R") { wizard.redoSide(.right) }
                }
                .font(.caption)
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    private func sideBadge(_ label: String, trials: [Double],
                           stats: (meanDB: Double, stdDB: Double)?) -> some View {
        let text: String
        if let stats {
            text = String(format: "%@ %.1f dB", label, stats.meanDB)
        } else if trials.isEmpty {
            text = "\(label) —"
        } else {
            text = "\(label) \(trials.count)/\(BalanceWizard.trialsPerSide)"
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(stats == nil ? .secondary : .primary)
    }
}

/// Leaf view: the only place `micLevel` is read, so the 30 fps level updates
/// re-render just this bar (see the EQView observation-isolation lesson).
private struct MicLevelBar: View {
    let wizard: BalanceWizard

    var body: some View {
        let db = 20 * log10(max(Double(wizard.micLevel), 1e-5))   // -100…0
        let t = min(max((db + 70) / 70, 0), 1)                    // -70 dB…0 dB
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .green, .yellow],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * t)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
    }
}
