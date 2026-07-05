# ParaEQ User Guide

## Installation

### Requirements

- macOS 14.4 (Sonoma) or later. No drivers or other software — ParaEQ uses
  Apple's built-in system-audio capture API.

### Build and install

ParaEQ is distributed as source. With Xcode command-line tools installed
(`xcode-select --install`):

```bash
git clone https://github.com/wabsto1/ParaEQ.git
cd ParaEQ
bash build.sh
cp -R .build/ParaEQ.app /Applications/
open /Applications/ParaEQ.app
```

ParaEQ appears as a slider icon in the menu bar — it has no Dock icon and no
main window.

### First run and permissions

1. Click the menu-bar icon, then click **Start**.
2. macOS asks for permission to record system audio ("ParaEQ would like to
   record system audio"). Click **Allow**. This is the only permission ParaEQ
   needs; you can review it later under **System Settings → Privacy &
   Security → Screen & System Audio Recording**.
3. Audio now flows through the EQ. Press **Stop** at any time to return to
   unprocessed audio.

If you build from source repeatedly, see the signing note in
[CONTRIBUTING.md](../CONTRIBUTING.md) — with plain ad-hoc signing macOS
re-asks for the permission after every rebuild.

## The main window

Top to bottom:

- **Start/Stop** — engages or disengages processing. **A/B** (visible while
  running) toggles bypass: the EQ, FIR, and crossfeed stages are skipped so
  you can compare processed vs. unprocessed instantly.
- **Output** — which device ParaEQ plays to. "System Default" follows whatever
  macOS routes audio to (recommended); picking a specific device locks output
  there. Unplugging a device or changing the system default is handled
  automatically.
- **Vol / Bal** — master volume and stereo balance.
- **FIR** — shows the active GraphicEQ curve or loaded impulse response
  (see below); **Load IR…** loads a convolution file.
- **XFeed** — headphone crossfeed: Off, Chu Moy, or Jan Meier flavor.
  Crossfeed bleeds a low-passed, attenuated copy of each channel into the
  other, easing the "in-head" feeling of headphones.
- **Pre** — preamp. **Auto** (recommended) lowers gain exactly enough that
  your biggest EQ boost cannot clip; uncheck it for a manual preamp slider.
- **Level meter** — post-limiter stereo peaks while running.
- **Preset row** — see Presets below.
- **Frequency-response graph** — the exact curve the audio path applies.
  **Drag a band's dot** to change its frequency (horizontal) and gain
  (vertical). Faint lines show individual bands; the bold line is the sum.
- **Channel/band controls** — see below.
- **Reset** — back to a flat 10-band layout. **Start at Login** — launches
  ParaEQ automatically (processing auto-resumes if it was running when you
  quit). **Quit** — stops processing and exits.

## Bands

- The **N Bands** menu switches layouts: 5, 10, 15, or 31 bands at standard
  ISO frequencies (gains reset when switching).
- **＋** adds a band; **right-click a band row → Remove Band** deletes one.
- Click a band row to expand it: filter type, frequency (20 Hz–20 kHz, log),
  gain (±24 dB), and Q (0.1–30, log). The checkbox enables/disables the band.
- Filter types: **Peak** (parametric bell), **Low/High Shelf**, **Low/High
  Pass** (Q-adjustable), **Band Pass**, **Notch**, plus fixed-slope crossover
  types — **BW 6/24 dB-oct** (Butterworth) and **LR 12/24 dB-oct**
  (Linkwitz-Riley) low/high-pass. Gain/Q sliders hide for types they don't
  affect.

## Channel modes

The channel picker above the band list selects how the two channels are EQ'd:

- **Stereo** — one set of bands applies to both channels.
- **L / R** — independent band sets per channel; the Left/Right tabs switch
  which one you're editing (useful for hearing asymmetry or room correction).
- **Mid / Side** — bands apply to the mono (Mid) and stereo-difference (Side)
  components. Cutting lows on Side tightens bass; boosting Side highs widens.

The graph and band list always show the set selected by the tabs.

## Presets

- The preset menu applies built-ins or your saved presets.
- **Save** (💾) stores the current curve under a name. **Delete** (🗑) removes
  a custom preset.
- **Import** (📄+) reads Equalizer APO / AutoEQ files — both `ParametricEQ.txt`
  (Preamp + Filter lines) and `GraphicEQ.txt` formats.
- **Export** (⬆) writes the current curve as an Equalizer APO
  `ParametricEQ.txt`, usable on Windows with Equalizer APO/Peace (crossover
  filter types are skipped — they have no APO equivalent).
- **Headphones** (🎧) opens the **AutoEQ database browser**: search your
  headphone model and click it to download and apply its correction profile
  (needs internet; the profile is saved as a custom preset).
- **Pin** (📌) assigns the selected preset to the *current output device*.
  Whenever audio routes to that device, the preset applies automatically —
  e.g. a correction preset for your headphones and a flat preset for speakers.
- **Hotkeys**: ⌘⌃1 through ⌘⌃9 apply the first nine presets (menu order),
  system-wide, even when ParaEQ isn't focused.

## GraphicEQ and convolution

- Importing an AutoEQ **GraphicEQ** profile activates a FIR filter stage shown
  in the **FIR** row (rendered as a minimum-phase filter — no audible
  latency). Click ✕ to remove it.
- **Load IR…** loads an impulse-response audio file (WAV/AIFF/…, mono or
  stereo, any sample rate — it's resampled automatically). Use this for room
  correction filters, headphone target IRs, etc. The FIR stage adds ~11 ms of
  latency — fine for music, noticeable for gaming.
- The FIR stage runs *in addition to* the parametric bands.

## Limiter

A lookahead limiter (not a clipper) protects the output: transients are caught
before they clip, and steady content is transparent below the ceiling. With
**Auto preamp** on you will rarely engage it; it exists as a safety net for
manual preamp settings and IR filters.

## Troubleshooting

- **No audio through the EQ / silence when starting** — check the permission
  in System Settings → Privacy & Security → Screen & System Audio Recording;
  quit and relaunch after granting.
- **Engine details** — `~/Library/Logs/ParaEQ.log` records starts, stops,
  device changes, and a status line every 10 seconds while running (callback
  count and peak levels). Include it when reporting issues.
- **Some audio is unaffected** — apps using exclusive-mode device access
  bypass the system mix (rare on macOS; some pro-audio apps).
- **Balanced but shifted volume after big boosts** — that's auto-preamp
  compensating; the overall loudness drop equals your largest boost.
