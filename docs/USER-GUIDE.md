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

**Getting oriented:** hover over any control — its description appears
instantly in the **hint bar** just above the Reset/Quit row (a native tooltip
also appears at the cursor after half a second). Everything below is also
explained in [Reference: terms and filter types](#reference-terms-and-filter-types).

Top to bottom:

- **Start/Stop** — engages or disengages processing. **A/B** (visible while
  running) toggles bypass: the EQ, FIR, and crossfeed stages are skipped so
  you can compare processed vs. unprocessed instantly.
- **Pop-out** (window icon next to the title) — opens the same interface in
  a **resizable window** that stays open while you work in other apps; the
  graph grows with the window, which suits spectrum-watching. The panel and
  the window control the same engine and stay in sync.
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
- **Preset row** — see Presets below. An **orange dot** next to the preset
  menu means your current curve has been edited away from the selected
  preset — use Save to keep it.
- **Graph toolbar** — undo (⌘Z) / redo (⇧⌘Z) of EQ edits, the **spectrum
  toggle** (waveform icon, while running), and the **gain-range menu**
  (±6/12/18/24 dB or Auto, which fits the range to your current curve).
- **Frequency-response graph** — the exact curve the audio path applies.
  **Drag a band's dot** to change its frequency (horizontal) and gain
  (vertical); the dragged band gets a selection ring. Faint lines show
  individual bands; the bold line is the sum. With the spectrum enabled, a
  **live spectrum analyzer** draws behind the curve: **cyan = source audio
  (pre-EQ), orange = after EQ** — you can watch your boosts and cuts act on
  real program material.
- **Channel/band controls** — see below.
- **Reset** — back to a flat 10-band layout. **Start at Login** — launches
  ParaEQ automatically (processing auto-resumes if it was running when you
  quit). **?** opens this guide. **Quit** — stops processing and exits.

## Bands

- The **N Bands** menu switches layouts: 5, 10, 15, or 31 bands at standard
  ISO frequencies (gains reset when switching).
- **＋** adds a band **centered in the largest gap** of your current layout,
  with Q matched to the gap width; **right-click a band row → Remove Band**
  deletes one.
- Click a band row to expand it: filter type, frequency (20 Hz–20 kHz, log),
  gain (±24 dB), and Q (0.1–30, log). The checkbox enables/disables the band.
- **Q or octaves**: click the **Q** label (in a band row or its expanded
  controls) to switch the width display between Q factor and **bandwidth in
  octaves** — the two are equivalent; use whichever you think in.
- Filter types: **Peak** (parametric bell), **Low/High Shelf**, **Low/High
  Pass** (Q-adjustable), **Band Pass**, **Notch**, plus fixed-slope crossover
  types — **BW 6/24 dB-oct** (Butterworth) and **LR 12/24 dB-oct**
  (Linkwitz-Riley) low/high-pass. Gain/Q sliders hide for types they don't
  affect. Every type and parameter is explained in [Reference: terms and filter types](#reference-terms-and-filter-types).

## Channel modes

The channel picker above the band list selects how the two channels are EQ'd:

- **Stereo** — one set of bands applies to both channels.
- **L / R** — independent band sets per channel; the Left/Right tabs switch
  which one you're editing (useful for hearing asymmetry or room correction).
- **Mid / Side** — bands apply to the mono (Mid) and stereo-difference (Side)
  components. Cutting lows on Side tightens bass; boosting Side highs widens.

The graph and band list always show the set selected by the tabs.

## Keyboard shortcuts

While the ParaEQ window is open:

| Keys | Action |
|---|---|
| **Tab / ⇧Tab** | Select the next / previous band (highlighted in the list and on the graph) |
| **↑ / ↓** | Selected band's gain ±0.5 dB (**⇧** for ±0.1 dB) |
| **← / →** | Selected band's frequency down/up one semitone (**⇧** for fine steps) |
| **⌘Z / ⇧⌘Z** | Undo / redo EQ edits (slider drags count as one edit) |
| **⌘B** | Toggle A/B bypass (while running) |

System-wide (even when ParaEQ isn't focused): **⌘⌃1–9** apply the first nine
presets in menu order.

## Presets

- The preset menu applies built-ins or your saved presets. Built-ins include
  tonal starters (Bass Boost, Vocal Clarity, Treble Boost, **Loudness,
  Podcast, Electronic, Rock**) alongside Flat and headphone corrections.
- An **orange dot** appears when the current curve differs from the selected
  preset. Built-ins are never overwritten — Save your edited version under a
  new name.
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

## Reference: terms and filter types

### The three band parameters

- **Freq (frequency, Hz)** — where on the spectrum the filter acts. Human
  hearing spans ~20 Hz–20 kHz. Rough landmarks: sub-bass 20–60 Hz, bass
  60–250 Hz, low mids 250–500 Hz ("mud" lives here), mids 500 Hz–2 kHz
  (vocals, instruments), presence 2–6 kHz (clarity, harshness), treble/air
  6–20 kHz (sparkle, sibilance). The sliders are logarithmic because hearing
  is: each octave (doubling of frequency) feels like an equal step.
- **Gain (dB)** — how much the filter boosts (+) or cuts (−) at its center.
  Decibels are logarithmic: +6 dB ≈ double the amplitude, +10 dB ≈ twice as
  *loud* perceptually. ±3 dB is a clearly audible change; ±12 dB is drastic.
  Cuts usually sound more natural than boosts.
- **Q (quality factor)** — how *narrow* the filter is. Low Q (0.5–0.7) = broad,
  gentle, musical shaping across several octaves. Q ≈ 1.4 covers about one
  octave. High Q (5–30) = surgical: hitting a single resonance or hum
  frequency without touching neighbors. (Q relates inversely to bandwidth-in-
  octaves; Equalizer APO's "BW Oct" notation is the same idea and is converted
  on import.) For Low/High Pass, Q instead controls the *knee*: 0.707 is
  maximally flat (Butterworth); higher values add a resonant bump right at the
  cutoff before the roll-off.

### Filter types

**Tone-shaping types** (use Gain):

- **Peak** (parametric bell) — boosts or cuts a bell-shaped region around the
  center frequency; width set by Q. The workhorse: 90 % of EQ moves are peaks.
  Example: −4 dB at 3 kHz, Q 2 to tame a harsh presence peak.
- **Low Shelf** — raises or lowers *everything below* the corner frequency by
  the gain amount, flat above it. Natural-sounding bass adjustment ("more/less
  bass overall") without the narrowness of a peak. Q shapes how abrupt the
  transition is.
- **High Shelf** — the mirror image: shifts everything *above* the corner.
  "More air" (+2 dB at 8 kHz) or "less sizzle" (−3 dB at 10 kHz).

**Removal types** (Gain doesn't apply — they only take away):

- **Low Pass** — lets lows through, progressively removes everything *above*
  the cutoff at 12 dB per octave. Use: taming extreme treble, lo-fi effects,
  subwoofer feeds. Q sets the knee (see above).
- **High Pass** — the mirror: removes everything *below* the cutoff. The
  classic "rumble filter": 20–30 Hz high-pass removes inaudible sub-rumble
  that wastes amplifier headroom.
- **Band Pass** — keeps only a band around the center, rolls off both sides.
  Telephone/radio effects, isolating a range.
- **Notch** — the opposite of band pass: a deep, narrow cut at exactly the
  center frequency. Purpose-built for killing a single tone: 50/60 Hz mains
  hum, a feedback whistle, one ringing room resonance. Pair with high Q.

**Crossover types** (fixed shape — Gain and Q don't apply):

These are Low/High Pass filters with standardized, steeper roll-offs, named by
slope. "dB/oct" is how fast the filter attenuates past the cutoff: 6 dB/oct is
a gentle analog-style slope; 24 dB/oct is steep (two octaves past cutoff ≈
−48 dB, effectively gone). Steeper = more surgical separation, at the cost of
more phase rotation near the cutoff.

- **BW (Butterworth)** — "maximally flat": the passband stays perfectly level
  right up to the cutoff, where the response is −3 dB. Best when you just want
  content above/below a point gone (rumble removal, harshness ceiling).
  Offered at 6 and 24 dB/oct.
- **LR (Linkwitz-Riley)** — the speaker-crossover standard, −6 dB at the
  cutoff. Its defining property: a matching LR low-pass and high-pass at the
  same frequency sum back to perfectly flat, which is why it's used to split
  audio between drivers (woofer/tweeter) or for bass-management setups.
  Offered at 12 and 24 dB/oct.

If you're not building crossovers or feeding multi-amp speakers, the plain
Q-adjustable Low/High Pass types are usually all you need.

### Other terms in the app

- **Preamp** — a plain gain stage *before* the EQ. Boosting a band can push
  peaks past digital full scale (0 dBFS), which would clip; lowering the
  preamp by the size of your biggest boost prevents that. **Auto** does this
  calculation continuously from the actual response curve.
- **Limiter** — the safety net after everything else. It looks 5 ms ahead,
  and when a peak would exceed the ceiling it smoothly turns the level down
  just for that moment (and releases over ~60 ms) instead of flattening the
  waveform the way a clipper would. Below the ceiling it is bit-transparent.
- **Balance** — relative L/R level, applied after the EQ.
- **Crossfeed** — on headphones, each ear hears only one channel, which feels
  "inside the head." Crossfeed mimics speakers in a room by bleeding a
  low-passed (head-shadowed), quieter copy of each channel into the opposite
  ear. Chu Moy and Jan Meier are two classic analog circuit flavors (slightly
  different corner frequencies).
- **Mid/Side** — any stereo signal can be re-expressed as Mid (L+R: the mono
  center — vocals, bass, kick) and Side (L−R: the stereo edges — ambience,
  width). EQing them separately lets you e.g. tighten bass only in the center
  or add air only to the sides.
- **GraphicEQ** — instead of a handful of parametric bands, a curve defined by
  many frequency/gain points (AutoEQ publishes profiles this way). ParaEQ
  renders the curve as a single precise FIR filter.
- **FIR / IR / Convolution** — an *impulse response* (IR) is a complete
  fingerprint of a system's frequency and phase behavior; *convolution*
  applies that fingerprint to audio. Room-correction packages and headphone
  target simulations ship as IR files; **Load IR…** applies them. *Minimum
  phase* (used for GraphicEQ) means the filter is arranged to respond as early
  as possible, keeping latency near zero.
- **Peak meter / dBFS** — the bars show the post-limiter peak level per
  channel. Digital audio clips at full scale (0 dBFS); the limiter's ceiling
  sits just below it.
- **Spectrum analyzer** — a live view of how much energy the audio contains
  at each frequency (FFT of the last ~43 ms, updated 30×/s). ParaEQ shows two:
  **cyan** is the source before any processing, **orange** is after the full
  EQ chain — the vertical distance between them at any frequency is what your
  settings are actually doing to the material playing right now. The spectrum
  uses its own level scale (0 dBFS at the top of the graph, −90 dB at the
  bottom), independent of the EQ-curve gain range.
- **Bandwidth (octaves)** — an alternative way to state a filter's width:
  the distance between its half-gain points measured in octaves. Q 1.41 ≈ 1
  octave; Q 4.32 ≈ ⅓ octave. Click the Q label to switch displays.

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
