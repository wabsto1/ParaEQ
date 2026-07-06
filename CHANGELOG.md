# Changelog

## 2.1.0 — 2026-07-05

Workflow and visualization release (inspired by a feature review against
[iQualize](https://github.com/dariuscorvus/iqualize)).

### Added
- **Real-time spectrum analyzer**: pre-EQ (cyan) and post-EQ (orange)
  spectra rendered live behind the response curve. 2048-point Hann-windowed
  FFT of a lock-free ring-buffer capture, 30 fps, peak-picked log binning,
  3 dB/frame release smoothing. Toggle with the waveform button; the
  preference persists.
- **Undo/redo** (⌘Z/⇧⌘Z + toolbar buttons) covering bands, both channel
  sets, and preamp. Slider/drag gestures coalesce into single undo steps.
- **Keyboard editing**: Tab/⇧Tab cycles band selection (highlighted in list
  and graph), ↑/↓ nudges gain ±0.5 dB, ←/→ moves frequency by a semitone
  (⇧ = fine steps), ⌘B toggles bypass.
- **Graph gain range**: ±6/12/18/24 dB or Auto (fits the current curve).
- **Q ↔ bandwidth-in-octaves display toggle** (click the Q label).
- **Smarter add-band**: ＋ now inserts the new band centered in the largest
  log-frequency gap, Q matched to the gap width.
- **Edited-preset indicator**: an orange dot marks when the curve has
  diverged from the selected preset.
- Four new built-in presets: Loudness, Podcast, Electronic, Rock.
- **?** button opening the user guide.
- **Pop-out window**: the window icon in the header opens the full UI in a
  resizable window (graph height scales); shares the engine with the panel,
  and keyboard handling is scoped per window.
- 15 new unit tests (spectrum calibration, undo history coalescing,
  bandwidth conversion round-trip, suggested-band placement, auto range).

### Changed
- Pre-EQ audio is now staged raw and preamp applied as a separate pass
  (needed for the pre-EQ spectrum; no audible change).
- Window grew 26 pt taller for the graph toolbar.
- Preset hotkey (⌘⌃1–9) order shifts where the new built-ins appear.

## 2.0.0 — 2026-07-05

Complete architecture and feature overhaul.

### Engine
- **Replaced the BlackHole virtual-driver architecture with Core Audio process taps** (macOS 14.4+ API): a global tap with `.mutedWhenTapped` feeds a private aggregate device; one IOProc captures, processes, and outputs. No driver install, no default-device hijacking, crash-safe.
- **Replaced Apple's NBandEQ with a native vDSP biquad engine** (`vDSP_biquadm`, RBJ Audio-EQ-Cookbook coefficients, per-sample coefficient ramping for glitch-free edits). The response graph now shows the exact coefficients the audio path runs, at the real sample rate.
- **Lookahead limiter** (5 ms lookahead, sliding-window-minimum attack, 60 ms release) replaces the hard clipper.
- **GraphicEQ**: variable-node curves rendered as 16384-tap minimum-phase FIRs (cepstral method).
- **Convolution**: streaming partitioned FFT convolver; IR files load with automatic resampling.
- **Per-channel processing**: independent Left/Right or Mid/Side band sets; stereo balance; Chu Moy / Jan Meier crossfeed.

### Features
- 5/10/15/31-band layouts plus free add/remove of bands
- Butterworth 6/24 dB-oct and Linkwitz-Riley 12/24 dB-oct crossover filter types
- A/B bypass, drag-to-edit response graph, global preset hotkeys (⌘⌃1–9)
- Device auto-profiles (pin a preset to an output device)
- AutoEQ online database browser
- Equalizer APO import (Parametric + GraphicEQ formats) **and export** (round-trip tested)
- Auto-resume on launch, Start-at-Login, device hot-plug handling, diagnostics log
- Hover help everywhere: instant hint bar + native tooltips (500 ms delay) on every control

### Infrastructure
- 37-test DSP/parser suite (`swift test`)
- Stable local codesigning identity support in `build.sh` (keeps the TCC grant across rebuilds)

## 1.0.0 — 2026-02

Initial release: 10-band parametric EQ over a BlackHole loopback capture with dual AUHAL units, NBandEQ processing, presets, AutoEQ import, peak meter, auto-preamp.
