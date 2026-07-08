# ParaEQ

A system-wide parametric equalizer for macOS, living in your menu bar. Captures system audio through Apple's Core Audio process-tap API (macOS 14.4+), processes it with a native vDSP filter engine, and plays it out to your headphones or speakers — no virtual audio driver, no kernel extensions, no default-device hijacking.

[![CI](https://github.com/wabsto1/ParaEQ/actions/workflows/ci.yml/badge.svg)](https://github.com/wabsto1/ParaEQ/actions/workflows/ci.yml)

Built with SwiftUI and pure CoreAudio/Accelerate — no external dependencies.

<p align="center">
  <img src="docs/images/screenshot.png" width="420" alt="ParaEQ menu-bar window: output device, volume/balance, FIR and crossfeed controls, preamp, preset row, frequency-response graph, and the 10-band list">
</p>

## Features

**EQ engine**
- Parametric EQ with **5 / 10 / 15 / 31-band layouts**, plus add/remove-band freedom
- **15 filter types**: Peak, Low/High Shelf, Low/High Pass (variable Q), Band Pass, Notch, and Butterworth 6/24 dB-oct + Linkwitz-Riley 12/24 dB-oct crossovers (expanded into biquad cascades)
- **Per-channel EQ**: stereo-linked, independent Left/Right, or **Mid/Side** processing
- **GraphicEQ mode**: variable-node curves rendered as 16384-tap minimum-phase FIR filters (cepstral method — no pre-ringing; the FIR stage adds ~11 ms, see FAQ)
- **Convolution**: load impulse-response files (wav/aiff/…, auto-resampled) through a partitioned FFT convolver
- **Headphone crossfeed** (Chu Moy / Jan Meier style)
- **Stereo balance** (slider or typed — `0`/`C`, `L20`, `R15`), master volume, auto- or manual **preamp** (anti-clipping)
- **App Mixer**: per-application volume (−60…+6 dB) and mute, in a collapsible panel section — adjust one app without touching the rest
- **Mic-based balance calibration**: a guided wizard plays a multitone test signal per channel while you hold each earcup to the Mac's microphone, detects it per-frequency (robust to fan/room noise), and applies the true L/R correction — catches worn cables, dirty plug contacts, and mismatched drivers
- **Lookahead limiter** (5 ms lookahead, instant attack, smooth release) instead of a clipper

**Interface**
- **Real-time spectrum analyzer**: pre-EQ (cyan) and post-EQ (orange) spectra drawn live behind the response curve — watch your EQ act on the actual program material
- Live frequency-response graph computed from the *exact* coefficients the audio path runs — **drag band dots** to edit frequency/gain directly; ±6/12/18/24 dB or auto-scaling gain range
- **Undo/redo** (⌘Z/⇧⌘Z) for all EQ edits, with slider drags coalesced into single steps
- **Keyboard editing**: Tab cycles band selection, arrow keys nudge gain/frequency (⇧ for fine steps), ⌘B toggles bypass
- **A/B bypass** button for instant EQ on/off comparison
- Band width shown as **Q or bandwidth-in-octaves** (click the Q label to switch); **＋** adds a band centered in the largest gap of the current curve
- Stereo peak meter; per-band expandable controls; edited-preset indicator
- **Pop-out window**: the full UI in a resizable window (graph scales up) alongside the menu-bar panel
- Global **preset hotkeys ⌘⌃1–9**

**Presets & interop**
- Built-in tonal and genre presets (Loudness, Podcast, Electronic, Rock, …) plus custom presets; **pin a preset to an output device** and it applies automatically when audio routes there
- **AutoEQ database browser** — search thousands of headphone correction profiles and apply them in one click
- **Import** Equalizer APO / AutoEQ files (`Preamp:`, `Filter N:`, `GraphicEQ:` lines, Q or BW Oct)
- **Export** your curve as Equalizer APO `ParametricEQ.txt` (round-trip compatible)

**System behavior**
- Zero-install capture: one "System Audio Recording" permission prompt, nothing else
- Follows the system default output (or a selected device); survives device hot-plug and default-device changes
- Auto-resumes processing on launch; optional Start-at-Login
- Crash-safe: the system default device is never touched, and settings save within ~1 s of every change
- Diagnostics log at `~/Library/Logs/ParaEQ.log`

> Turn the volume down before applying large boosts or unfamiliar presets — an EQ boost is a real level increase. See [Listening safely](docs/USER-GUIDE.md#listening-safely) in the User Guide.

## Requirements

- macOS 14.4 (Sonoma) or later — the Core Audio process-tap API is required
- Developed and tested on Apple Silicon; Intel is untested
- No drivers or additional software

## Installation

Download `ParaEQ.zip` from the [Releases page](https://github.com/wabsto1/ParaEQ/releases), unzip, and drag ParaEQ to Applications. ParaEQ lives in the menu bar (slider icon) — it has no Dock icon — and nothing changes until you press **Start**.

A note before the first launch: macOS labels any system-audio capture "recording", so pressing Start prompts for the **System Audio Recording** permission. ParaEQ only passes audio through its filters in real time — nothing is written to disk. The optional balance calibration separately prompts for microphone access when you first use it. See the **[User Guide](docs/USER-GUIDE.md)** for a full walkthrough of every feature.

<details>
<summary>Build from source</summary>

With Xcode command-line tools installed (`xcode-select --install`):

```bash
git clone https://github.com/wabsto1/ParaEQ.git
cd ParaEQ
bash build.sh
cp -R .build/ParaEQ.app /Applications/
open /Applications/ParaEQ.app
```

Rebuild tip: `build.sh` prefers a codesigning identity named "ParaEQ Dev Signing" if present in your keychain, so the TCC permission survives rebuilds. With plain ad-hoc signing, macOS re-prompts after every rebuild.

</details>

## Architecture

```
System audio → global process tap (.mutedWhenTapped, own PID excluded)
             → private aggregate device (real output device + tap)
             → single IOProc:
                 [Mid/Side encode] → vDSP biquad cascades (per-channel coefficients)
                 → [minimum-phase FIR / convolution] → [crossfeed]
                 → balance + volume → [calibration stimulus] → lookahead limiter
                 → output buffers
```

Filter math is RBJ Audio-EQ-Cookbook biquads run through `vDSP_biquadm` with per-sample coefficient ramping (glitch-free live edits). The response graph evaluates the same coefficients at the engine's actual sample rate.

## Testing

```bash
swift test   # 130+ DSP/parser/logic tests: coefficients, slopes, limiter, FIR design, convolver, round-trips, spectrum calibration, undo history, calibration signal/detection/statistics, App Mixer policy
```

**[User Guide](docs/USER-GUIDE.md)** (installation, permissions, every feature) · [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · [CHANGELOG.md](CHANGELOG.md) · [CONTRIBUTING.md](CONTRIBUTING.md)

## Privacy

- No telemetry, no analytics, no accounts.
- The only network access is fetching headphone profiles from the public
  [AutoEq](https://github.com/jaakkopasanen/AutoEq) GitHub repository
  (`raw.githubusercontent.com`), and only when you open the headphone
  browser. Nothing is uploaded, ever.
- The microphone is used only during the user-initiated balance calibration,
  analyzed in memory, and never recorded to disk or transmitted.
- Audio never leaves the audio pipeline. A local diagnostic log at
  `~/Library/Logs/ParaEQ.log` records device names and status lines only,
  never audio content.
- No sandbox escape hatches: the app requests exactly one thing beyond
  defaults — audio capture.

## FAQ

**Does it add latency?** Yes, a little. The lookahead limiter adds a fixed
5 ms; the FIR stage (GraphicEQ or IR convolution) adds a 512-sample block on
top (~10.7 ms at 48 kHz); normal device buffering applies either way. Total:
roughly 5–10 ms for parametric EQ, ~16–21 ms with GraphicEQ or IR loaded.
Inaudible for music, fine for video, may matter for rhythm games. The
parametric-only path has no FIR in it — the stage only exists while a
GraphicEQ curve or IR is loaded.

**How much CPU?** A few percent with the panel closed. The spectrum analyzer
costs more while the panel is open.

**Why does macOS say ParaEQ wants to RECORD my audio?** macOS calls any
system-audio capture "recording". ParaEQ only passes audio through its
filters in real time; nothing is written to disk.

**Do Bluetooth devices work?** Yes, but they add their own codec latency on
top of ParaEQ's.

**Some audio isn't affected.** Other process-tap apps and some DRM paths can
bypass the system mix — see the
[User Guide troubleshooting section](docs/USER-GUIDE.md#troubleshooting).

## How it compares

[eqMac](https://eqmac.app) is full-featured but installs a virtual audio
driver. [SoundSource](https://rogueamoeba.com/soundsource/) from Rogue Amoeba
is excellent and paid ($47). Apple's built-in options cover headphone
accommodations only — there is no system-wide parametric EQ. ParaEQ's angle:
native process-tap capture (the macOS 14.4+ API), no driver or kext, the
system output device is never touched, free and open source, and crash-safe
by construction — if ParaEQ dies, your audio continues unprocessed.

## Uninstalling

Quit ParaEQ (its private audio device and taps are removed the moment it
stops — nothing is installed system-wide) and delete `/Applications/ParaEQ.app`.
No drivers, kernel extensions, launch daemons, or helpers are ever installed.
Optional leftovers and full details in the
[User Guide](docs/USER-GUIDE.md#uninstalling).

## Acknowledgments

- [AutoEq by Jaakko Pasanen](https://github.com/jaakkopasanen/AutoEq) (MIT) —
  the headphone-profile database the browser fetches.
- [Equalizer APO](https://equalizerapo.com) — the preset text format ParaEQ
  imports and exports.
- The RBJ Audio EQ Cookbook (Robert Bristow-Johnson) — the filter math.

## Support

ParaEQ is free and open source, and will stay that way. If it improves your
listening, you can [sponsor development](https://github.com/sponsors/wabsto1) —
entirely optional, always appreciated.

## License

MIT

---

ParaEQ is developed with heavy AI assistance (Claude); every DSP change is covered by unit tests (`swift test`, 130+) and verified live on hardware before merging.
