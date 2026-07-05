# Changelog

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

### Infrastructure
- 37-test DSP/parser suite (`swift test`)
- Stable local codesigning identity support in `build.sh` (keeps the TCC grant across rebuilds)

## 1.0.0 — 2026-02

Initial release: 10-band parametric EQ over a BlackHole loopback capture with dual AUHAL units, NBandEQ processing, presets, AutoEQ import, peak meter, auto-preamp.
