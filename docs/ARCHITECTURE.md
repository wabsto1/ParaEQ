# ParaEQ Architecture

## Signal flow

```
System audio (all apps except ParaEQ)
  → global Core Audio process tap        (.mutedWhenTapped, own PID excluded)
  → private aggregate device              (real output device = main sub-device,
                                           tap in the tap list, drift compensation)
  → single IOProc on a dedicated queue:
      1. stage tap input as planar L/R    (interleaved or planar handled)
         → pre-EQ spectrum ring write     (mono mix, lock-free)
         → × preamp
      2. [bypass? skip 2–4]
         [Mid/Side encode]
         vDSP_biquadm cascade chain       (per-channel coefficient sets)
         [Mid/Side decode]
         FIR stage                        (GraphicEQ min-phase FIR or loaded IR,
                                           partitioned FFT convolver)
         crossfeed                        (low-passed opposite-channel bleed)
      3. balance + volume
         [balance calibration: replace with multitone stimulus on one
          channel — after balance/volume so settings can't skew the
          per-ear measurement]
      4. lookahead limiter                (5 ms, linked stereo)
         → post-EQ spectrum ring write
      5. copy to device output buffers, track peaks
```

Key point: the tap arrives as IOProc *input* on the same callback that writes the
device *output* — there is no ring buffer, no second audio unit, and the system
default device is never modified. A crash cannot leave the machine silent.

### App Mixer (exception taps)

Per-app volume/mute is layered onto the same aggregate rather than a parallel
pipeline. Each app the user adjusts (an "exception") gets its **own** process
tap (`.mutedWhenTapped`, `stereoMixdownOfProcesses: [pid]`) and is excluded
from the global tap's process list; the global tap and every exception tap all
live in the **one** private aggregate, so there is still a single IOProc.
Hardware-verified by the Task 1 spike: each tap arrives as its own
interleaved-stereo input buffer on the IOProc callback, in tap-list order with
the global tap first.

`InputStaging` (`Sources/InputStaging.swift`) sums the global pair plus each
active exception buffer, each multiplied by one of **16 preallocated gain
slots**, into the stage buffers the existing DSP chain already reads from —
so the M/S → biquad → FIR → crossfeed → balance/volume → limiter chain is
unaware App Mixer exists.

Two different update paths, deliberately:

- **Exception-set changes** (an app newly adjusted, or returned to neutral
  after its 30 s grace period) change which taps exist, so they go through a
  full **engine restart** — tear down and rebuild the aggregate/taps. This is
  the only path verified not to corrupt tap/aggregate state (see gotcha 1
  below); it costs a ~50 ms audio gap.
- **Gain-only changes** (slider drag, mute toggle) on an already-adjusted app
  write directly into that app's preallocated gain slot — no restart, no
  gap, safe from the IO thread's read.

A 30 s grace period after an app returns to neutral (0 dB, unmuted) delays
the teardown restart, so quick back-and-forth adjustments don't thrash the
aggregate. The exception set is capped at 16; if creating a given app's
exception tap fails, that app's exception is dropped and the rest of the
engine (global tap, other exceptions) keeps running unaffected.

## Files

| File | Role |
|---|---|
| `Sources/AudioEngine.swift` | Tap/aggregate/IOProc lifecycle, device-change handling, persistence |
| `Sources/BiquadEQ.swift` | RBJ coefficients, crossover cascades, `vDSP_biquadm` wrapper |
| `Sources/Limiter.swift` | Lookahead limiter (sliding-window minimum + exponential release) |
| `Sources/Convolution.swift` | Min-phase FIR design (cepstral) + streaming partitioned convolver |
| `Sources/Crossfeed.swift` | Channel modes, crossfeed processor |
| `Sources/IRLoader.swift` | IR file loading/resampling via AVAudioFile |
| `Sources/FrequencyResponse.swift` | Graph/auto-preamp math (same coefficients as audio) |
| `Sources/Spectrum.swift` | Lock-free spectrum capture rings + Hann/FFT analysis (`SpectrumTap`) |
| `Sources/EditHistory.swift` | Generic undo/redo stack with gesture coalescing |
| `Sources/BandUtils.swift` | Q↔octave conversion, suggested-band placement, graph auto-range, balance text entry (`BalanceEntry`) |
| `Sources/AutoEQParser.swift` | Equalizer APO Parametric/GraphicEQ import + export |
| `Sources/HotkeyManager.swift` | Carbon global hotkeys (no Accessibility permission needed) |
| `Sources/MeasurementSignal.swift` | Calibration stimuli: `MultiTone` (8 tones, unit RMS, realtime-safe) + `PinkNoise` |
| `Sources/BalanceCalibration.swift` | Goertzel tone detection, robust per-tone/block/trial statistics, balance recommendation |
| `Sources/MicCapture.swift` | Raw-HAL microphone input IOProc (mic-array mix-down) + `MonoRing` |
| `Sources/BalanceWizardView.swift` | Calibration wizard: seal gate, interleaved 3-trials-per-ear state machine, window UI |
| `Sources/AppMixer.swift` | App Mixer policy: per-app gain/mute settings, exceptions, grace period, 16-slot cap, persistence |
| `Sources/AppAudioDirectory.swift` | HAL process discovery — enumerates apps currently registering audio output, grouped by app |
| `Sources/InputStaging.swift` | Sums global + per-exception tap buffers × gain slots into the DSP chain's stage buffers |
| `Sources/AppMixerView.swift` | Collapsible per-app volume/mute panel section |
| `Sources/EQView.swift`, `FrequencyResponseView.swift`, `AutoEQPickerView.swift`, `LevelMeterView.swift` | SwiftUI menu-bar UI |
| `Prototypes/TapProto/` | Minimal standalone tap validation prototype (kept as reference) |

## Hard-won platform gotchas

These cost real debugging time; do not regress them.

1. **HAL listener deadlock.** Property listeners registered on the main queue +
   engine teardown on the main thread deadlock: `AudioDeviceDestroyIOProcID`
   messages coreaudiod synchronously while coreaudiod waits to deliver a
   notification to our blocked main queue. Listeners live on a dedicated
   `listenerQueue` the engine never blocks.
2. **Self-triggered restarts.** Creating/destroying our own aggregate fires
   `kAudioHardwarePropertyDevices`. Only restart when the *effective output
   UID* actually changed.
3. **App Nap.** A windowless menu-bar app gets napped: main-thread timers stop
   while HAL IO continues. Hold `ProcessInfo.beginActivity(.userInitiated,
   .latencyCritical)` while running.
4. **TCC + signing.** The System Audio Recording grant is keyed to the signing
   identity. Ad-hoc signing = new hash every rebuild = permission re-prompt.
   `build.sh` uses the "ParaEQ Dev Signing" keychain identity when present.
5. **macOS 26:** `AudioDeviceCreateIOProcIDWithBlock` requires a non-nil
   dispatch queue (nil silently registers nothing).
6. **Aggregate shape.** The real output device must be the aggregate's main
   sub-device with the tap in `kAudioAggregateDeviceTapListKey`; a tap-only
   aggregate silently produces zeros. Never touch `CATapDescription.isExclusive`
   after init (it inverts include/exclude semantics).
7. **Realtime hygiene.** No allocation on the IO thread: preallocated staging
   buffers, element-wise writes into convolver history (array assignment would
   COW-allocate), `vDSP_biquadm_SetTargetsDouble` for lock-free coefficient
   updates. Control values are single-word floats written by the main thread
   and read by the IO thread (word-atomic on AArch64).
8. **Stalled aggregate after rapid create/destroy.** Quitting and relaunching
   within seconds (or many tap/aggregate cycles in one coreaudiod session —
   e.g. repeated dev deploys) can yield a start where everything reports
   success ("Running" logged, `AudioDeviceStart` = noErr) but the IOProc is
   never invoked: `callbacks=0`, total silence. Observed 2026-07-07; even an
   immediate in-process restart stayed dead, while relaunching after ~45 s
   recovered. The engine runs a 5 s start watchdog (`scheduleStartWatchdog`)
   that restarts once and then surfaces an error; when developing, leave a
   pause between deploy cycles.
9. **UI observation isolation.** Any `@Observable` engine property mutated by
   the 30 fps meter timer (peaks, spectrum) must be read only in small leaf
   views, never in `EQView`'s body — a body-level read re-diffs the whole
   panel and re-runs AppKit layout 30×/s (~47% CPU). Same family: no blocking
   calls (SMAppService XPC, HAL device enumeration) in any view body.
10. **Tap create/destroy churn degrades coreaudiod short of a full wedge.**
    Heavy cycling of tap/aggregate creation (e.g. rapid App Mixer exception
    add/remove during development) can leave coreaudiod in a state where
    freshly created aggregates stall (`callbacks=0`) *and* `.mutedWhenTapped`
    stops muting the tapped process (audible double audio — the original app
    output plus the processed copy). `sudo killall coreaudiod` recovers this;
    a full wedge still needs a reboot. Design consequence: reconfigure taps
    only on explicit user action (the App Mixer exception design), never on
    app-lifecycle churn (app launch/quit alone must not create/destroy taps).
11. **TCC attribution requires a recognized GUI launch.** A binary capturing
    system audio must be launched by a recognized GUI process (e.g.
    double-clicked or opened via Terminal.app) — a headless/CLI-subprocess
    launch captures **silence with zero errors**: taps create fine, callbacks
    flow, buffers are all-zero. If live verification shows callbacks
    incrementing but everything's silent, check how the process was launched
    before suspecting the DSP chain.
12. **SIGTERM skips the "user stopped" persistence path correctly, but
    `killall` in scripts is still wrong for deploy cycles.** The app's normal
    termination path (used for both SIGTERM and menu Quit) persists
    `paraeq.wasRunning=0`, so the next launch won't auto-resume processing —
    by design, but easy to mistake for a bug when scripting relaunches. Use
    an AppleScript `quit` (or the Quit menu item) for deploy cycles so the
    persisted running-state matches what a real user would see.
13. **`vDSP_biquadm_SetTargetsDouble` argument order.** The signature is
    `(start_section, start_channel, n_sections, n_channels)` — passing counts
    in the offset slots compiles and runs with no error but silently updates
    zero sections. This shipped 2026-07-05 and made every live EQ edit (band
    drag, same-layout preset switch) a no-op in the running audio, even
    though the UI and coefficient math were correct; only full chain rebuilds
    (e.g. changing band count) picked up new coefficients. Fixed on `main` at
    `0d664eb`. Any future direct use of `vDSP_biquadm_SetTargetsDouble` /
    `vDSP_biquadm_SetTargets` needs a test that changes one coefficient live
    and asserts the *audio output* changed, not just that the call returned
    `noErr`.

## DSP notes

- Crossover types expand to cascades: BW24 uses pole Qs 0.5412/1.3066; LR is a
  squared Butterworth (LR12 = one Q 0.5 section, LR24 = two Q 0.7071 sections);
  6 dB/oct types are true first-order sections via bilinear transform.
- GraphicEQ FIR: target magnitude interpolated in log-frequency space on a
  16384-point grid → real cepstrum → fold → exp → minimum-phase impulse,
  half-Hann tail window. >95 % of the energy lands in the first 512 taps.
- Convolver: uniform-partition overlap-save, 512-sample internal blocks,
  input/output FIFOs absorb variable callback sizes (adds ~10.7 ms latency),
  IRs up to 131072 taps, mono or stereo.
- Limiter: linked-stereo sliding-window minimum over the lookahead window
  (monotonic deque, O(1) amortized per sample), instant attack by construction,
  exponential release, safety clamp at ±1.
- Spectrum analyzer: the IO thread writes mono-mixed samples into two
  2048-sample rings (single writer, plain stores — a read may tear by one
  callback at the seam, which the Hann window makes invisible). The meter
  timer (30 fps, main thread) snapshots each ring, windows, runs
  `vDSP_fft_zrip`, and peak-picks magnitudes into 120 log-spaced display
  bins (geometric-midpoint boundaries). Calibrated so a 0 dBFS sine reads
  0 dB (`refDB = 20·log10(N/2)` with the denormalized Hann window);
  release-smoothed at 3 dB/frame. Undo/redo snapshots (bands + preamp) are
  recorded through the same `applyAllBands`/`setPreamp` funnels the UI
  already uses, with sub-0.8 s bursts coalesced into one step.
- Balance calibration: differential per-ear level measurement — the same
  uncalibrated mic measures both cups, so mic response and coupling cancel
  in the L−R comparison. Stimulus is 8 log-spaced tones (500 Hz–4 kHz,
  unit-RMS sum, −20 dBFS injection); detection is one Goertzel per tone,
  so broadband room/fan noise contributes only what falls exactly on the
  tone bins (validated: level recovered within 0.5 dB under noise 10 dB
  above the stimulus). Robustness is layered medians: per tone across
  0.5 s blocks (movement), across three re-seated trials (placement,
  interleaved L,R,L,R,L,R so drift cancels), and across per-tone L−R
  deltas (a seating-killed tone). Ambient tone-bin power (captured before
  any stimulus) is subtracted per tone; a live seal gate arms Measure only
  after ~1 s of level stability. `balance = ±(1 − 10^(−|Δ|/20))` maps the
  measured delta onto the engine's linear one-side attenuation exactly.

## Testing

`swift test` — 124 tests covering coefficient correctness (center gains, shelf
asymptotes, crossover slopes/-3 dB/-6 dB points), the vDSP chain end-to-end
(sine gain, transparency, per-channel independence), limiter behavior (ceiling,
transparency, crest-factor preservation, transient catching), FIR design
accuracy, streaming convolution (identity, delay, multi-partition),
Equalizer APO import/export round-trips, spectrum calibration (0 dBFS sine,
floor, release), undo-history coalescing, Q↔octave round-trips,
suggested-band/auto-range placement, balance text entry, the calibration
stack (stimulus level/pinkness/tone isolation, Goertzel detection under
10 dB-louder noise, block/trial/tone-delta median robustness, ring-buffer
seams, recommendation math), and the App Mixer policy (gain/mute settings,
exception membership, grace period, slot cap, InputStaging summation).

Live verification: `~/Library/Logs/ParaEQ.log` logs engine starts, device
changes, and a status line (callback count + peaks) every 10 s while running.
