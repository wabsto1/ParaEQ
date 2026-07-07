# Mic-Based Headphone Balance Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure each headphone earcup's level with the Mac's microphone (pink-noise test signal, one channel at a time) and recommend/apply a balance correction for L/R level imbalance (bad cables, mismatched drivers).

**Architecture:** Differential measurement — the uncalibrated mic and earcup coupling cancel between the two per-ear captures. The engine's existing output IOProc injects pink noise post-balance/volume (so current settings can't skew the result) and pre-limiter. A new raw-HAL input IOProc records the mic into a lock-free mono ring (SpectrumTap pattern). Offline analysis band-limits to 250 Hz–4 kHz (where cup-to-mic coupling is most repeatable) and compares RMS. An @Observable wizard model drives a SwiftUI sheet with async/await sequencing.

**Tech Stack:** CoreAudio HAL (raw input; avoids voice-isolation/AGC coloring), Accelerate/vDSP, SwiftUI + Observation (@Observable), XCTest. No new dependencies.

## Global Constraints

- macOS 14.4+ platform; macOS 26 requires a **non-nil dispatch queue** for `AudioDeviceCreateIOProcIDWithBlock`.
- IO callbacks: no allocation, no locks, no Swift array assignment into long-lived storage.
- HAL property listeners stay on `listenerQueue`, never `.main`.
- Every DSP change gets a unit test; verify live via `~/Library/Logs/ParaEQ.log`.
- 30 fps-updated observable properties may only be read in leaf-view bodies (this session's hard-won lesson).
- Sign with the "ParaEQ Dev Signing" identity via `build.sh` (TCC survival).
- Commits only when the user asks (CLAUDE.md rule overrides skill defaults).

---

### Task 1: Pink-noise measurement signal

**Files:**
- Create: `Sources/MeasurementSignal.swift`
- Test: `Tests/ParaEQTests/CalibrationTests.swift` (new file)

**Interfaces:**
- Produces: `struct PinkNoise { init(seed: UInt64 = ...); mutating func next() -> Float }` — realtime-safe (value type, no allocation), ~unit-variance-scaled so a −20 dBFS injection is `next() * MeasurementSignal.injectionAmplitude`.
- Produces: `enum MeasurementSignal { static let injectionAmplitude: Float /* -20 dBFS = 0.1 */ }`

**Steps:**
- [ ] Failing tests: deterministic for equal seeds; RMS of 48 000 samples within 0.05…0.35; no sample exceeds ±1 at injection amplitude scale headroom (|next()| < 4); pinkness — average energy 100–400 Hz exceeds 3.2–12.8 kHz by > 6 dB (FFT via vDSP).
- [ ] Implement: xorshift64* PRNG → uniform ±1 white → Paul Kellet 3-pole pink filter (b0=0.99765·b0+w·0.0990460 …), output scaled ×0.25.
- [ ] `swift test` green.

### Task 2: Calibration math (band-limited RMS + recommendation)

**Files:**
- Create: `Sources/BalanceCalibration.swift`
- Test: `Tests/ParaEQTests/CalibrationTests.swift`

**Interfaces:**
- Consumes: `BiquadCoefficients.cascade(for:sampleRate:)` with `.lrHighPass24`@250 Hz and `.lrLowPass24`@4 kHz `EQBand`s for the offline band-pass.
- Produces (all pure, `enum BalanceCalibration`):
  - `static func bandLimitedRMSdB(_ samples: [Float], sampleRate: Double) -> Double`
  - `static func blockStats(_ samples: [Float], sampleRate: Double) -> (meanDB: Double, stdDB: Double)` — 0.5 s blocks, first block dropped (filter settling).
  - `static func recommendation(leftDB: Double, rightDB: Double) -> (deltaDB: Double, balance: Float)` — `deltaDB = leftDB - rightDB`; louder side attenuated: `balance = sign(deltaDB) * (1 - pow(10, -abs(deltaDB)/20))`, clamped to ±0.5.

**Steps:**
- [ ] Failing tests: 1 kHz sine in-band RMS ≈ its true RMS ±0.5 dB; 50 Hz and 12 kHz sines attenuated ≥ 20 dB vs in-band; recommendation: left 2 dB louder → balance > 0 and `20·log10(1-balance) ≈ -2`; equal → (0, 0); end-to-end: pink noise vs same×0.8 → delta ≈ −20·log10(0.8)... (sign: right quieter → deltaDB>0) within ±0.15 dB; blockStats std small (<0.5 dB) for stationary noise.
- [ ] Implement: scalar Direct-Form-I cascade over the sample array (offline; allocation fine), 20·log10(rms) with −120 floor.
- [ ] `swift test` green.

### Task 3: Mic capture (raw HAL input IOProc + mono ring)

**Files:**
- Create: `Sources/MicCapture.swift`
- Test: `Tests/ParaEQTests/CalibrationTests.swift` (ring only; no hardware in CI)

**Interfaces:**
- Produces: `final class MonoRing { init(seconds: Double, sampleRate: Double); func write(_ data: UnsafePointer<Float>, stride: Int, frames: Int) /* realtime-safe */; func snapshot(seconds: Double) -> [Float]; func levelRMS(seconds: Double) -> Float }`
- Produces: `final class MicCapture { init?(); let deviceName: String; let sampleRate: Double; func start() throws; func stop(); func snapshot(seconds: Double) -> [Float]; func level() -> Float }` — default input device, own `DispatchQueue(label: "com.paraeq.mic-io")` (non-nil, macOS 26), input samples averaged across channels into the ring. First `AudioDeviceStart` triggers the system mic-permission prompt (Info.plist string in Task 6).

**Steps:**
- [ ] Failing tests (MonoRing): write-then-snapshot returns last N samples in order across the wrap seam; `levelRMS` of a known sine ≈ 1/√2·amplitude.
- [ ] Implement MonoRing (power-of-two capacity, mask indexing, single-writer plain stores — SpectrumTap pattern) and MicCapture (HAL: default input via `kAudioHardwarePropertyDefaultInputDevice`, `AudioDeviceCreateIOProcIDWithBlock` reading `inInputData`).
- [ ] `swift test` green.

### Task 4: Engine measurement mode (noise injection in the output IOProc)

**Files:**
- Modify: `Sources/AudioEngine.swift` (IOCtx + IOProc + API)

**Interfaces:**
- Produces: `enum MeasureChannel: Float { case off = 0, left = 1, right = 2 }` and `AudioEngine.setMeasureChannel(_:)`; `AudioEngine.measureChannel` observable for UI state.
- IOCtx gains `let measurePtr: UnsafeMutablePointer<Float>` and `var pink = PinkNoise()`.

**IOProc injection (after the balance/volume stage, before `c.limiter.process`):**
```swift
let measure = c.measurePtr.pointee
if measure != 0 {
    let toL = measure == 1
    for f in 0..<frames {
        let s = c.pink.next() * MeasurementSignal.injectionAmplitude
        c.outL[f] = toL ? s : 0
        c.outR[f] = toL ? 0 : s
    }
}
```
Program audio is replaced (muted) during measurement; EQ/balance/volume cannot affect the stimulus; the limiter stays as a safety net. Peak meters are post-limiter, so the 10 s status log line becomes the live verification hook (peak ≈ pink-noise peak on the driven side, ~0 on the other).

**Steps:**
- [ ] Add pointer allocation/teardown alongside `balancePtr` (allocate in `startIO`, deallocate in `teardown`, reset to `.off` on stop).
- [ ] Add injection block + API; `setMeasureChannel` writes the pointer and the observable var.
- [ ] `swift test` green (existing suite — no regression); live check deferred to Task 7.

### Task 5: Wizard model + sheet UI

**Files:**
- Create: `Sources/BalanceWizardView.swift` (model + view together; they change together)

**Interfaces:**
- Consumes: `MicCapture`, `BalanceCalibration`, `MeasurementSignal`, `engine.setMeasureChannel`, `engine.setBalance`, `BalanceEntry.label(for:)`.
- Produces: `@Observable final class BalanceWizard` — states `enum Phase { idle, ambient, prompt(Side), settling(Side), capturing(Side), result, failed(String) }`; async `run()` sequence per side: settle 0.6 s → capture 3.0 s → snapshot → stats; ambient pre-check requires stimulus ≥ 15 dB above the ambient band RMS, else `failed`. `micLevel: Float` updated by a 20 Hz `Timer` **only read by the small meter leaf view**.
- Produces: `struct BalanceWizardView: View` (sheet) — step copy, live mic meter, Start/Next/Re-measure/Apply/Cancel; result shows per-side mean ± std and the recommendation ("Right is 1.2 dB quieter — apply R13?"); Apply calls `engine.setBalance`, Cancel/`onDisappear` always calls `stop()` (measure off + mic stopped).

**Steps:**
- [ ] Implement model with `Task`-based sequencing (`try await Task.sleep`), cancellation-safe teardown.
- [ ] Implement sheet view (fixed ~320×420, matches panel styling, helpHint copy).
- [ ] Build cleanly; behavior verified in Task 7 (needs mic TCC + human hands).

### Task 6: Entry point + permissions + docs

**Files:**
- Modify: `Sources/EQView.swift` (button beside the Bal row → `.sheet`), `Info.plist` (`NSMicrophoneUsageDescription`), `docs/USER-GUIDE.md`, `CHANGELOG.md`.

**Steps:**
- [ ] `Image(systemName: "ear.badge.waveform")` borderless button in the Bal HStack; `@State private var showBalanceWizard`; sheet presents `BalanceWizardView(engine: engine)`. Disabled (with hint) when `!engine.isRunning`.
- [ ] Info.plist: "ParaEQ plays a test tone and listens with the microphone only during headphone balance calibration you start."
- [ ] USER-GUIDE section + CHANGELOG entry (Unreleased → 2.2.0 heading).

### Task 7: End-to-end verification

- [ ] `swift test` — full suite green.
- [ ] `bash build.sh`, deploy via `ditto`, relaunch.
- [ ] Panel open via AppleScript; CPU sanity (<10% with panel open).
- [ ] Start a measurement (wizard Start): verify in `ParaEQ.log` status line that the driven side's peak ≈ 0.3–0.4 (pink peaks at −20 dBFS RMS) and the other side ≈ 0 — proves injection + channel isolation live.
- [ ] Mic TCC prompt: **requires the user** to click Allow; then user performs the physical two-cup measurement. Everything else must already be verified by this point.

## Self-review notes
- Spec coverage: stimulus ✓ (T1/T4), capture ✓ (T3), math ✓ (T2), guided L-then-R flow ✓ (T5), apply balance ✓ (T5), cable-imbalance goal ✓ (differential design). Gap: none.
- Type consistency: `MeasureChannel` raw Float matches `measurePtr` writes; `BalanceCalibration.recommendation` returns `balance: Float` consumed by `engine.setBalance(Float)`. ✓
- The wizard reads `micLevel` only in a leaf meter view per the perf lesson. ✓
