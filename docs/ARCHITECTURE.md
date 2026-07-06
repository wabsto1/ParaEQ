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
      4. lookahead limiter                (5 ms, linked stereo)
         → post-EQ spectrum ring write
      5. copy to device output buffers, track peaks
```

Key point: the tap arrives as IOProc *input* on the same callback that writes the
device *output* — there is no ring buffer, no second audio unit, and the system
default device is never modified. A crash cannot leave the machine silent.

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
| `Sources/BandUtils.swift` | Q↔octave conversion, suggested-band placement, graph auto-range |
| `Sources/AutoEQParser.swift` | Equalizer APO Parametric/GraphicEQ import + export |
| `Sources/HotkeyManager.swift` | Carbon global hotkeys (no Accessibility permission needed) |
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

## Testing

`swift test` — 52 tests covering coefficient correctness (center gains, shelf
asymptotes, crossover slopes/-3 dB/-6 dB points), the vDSP chain end-to-end
(sine gain, transparency, per-channel independence), limiter behavior (ceiling,
transparency, crest-factor preservation, transient catching), FIR design
accuracy, streaming convolution (identity, delay, multi-partition),
Equalizer APO import/export round-trips, spectrum calibration (0 dBFS sine,
floor, release), undo-history coalescing, Q↔octave round-trips, and
suggested-band/auto-range placement.

Live verification: `~/Library/Logs/ParaEQ.log` logs engine starts, device
changes, and a status line (callback count + peaks) every 10 s while running.
