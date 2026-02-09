# ParaEQ

A lightweight menu bar parametric equalizer for macOS. Captures system audio through [BlackHole](https://github.com/ExistentialAudio/BlackHole), applies real-time 10-band EQ processing, and outputs to your headphones or speakers.

Built with SwiftUI and pure CoreAudio — no external dependencies.

## Features

- **10-band parametric EQ** with per-band frequency, gain, Q, and filter type controls
- **7 filter types**: Parametric, Low Shelf, High Shelf, Low Pass, High Pass, Band Pass, Notch
- **Live frequency response graph** with combined and individual band curves
- **Stereo peak level meter** with clipping indicators
- **Auto-preamp** that automatically reduces input gain to prevent clipping
- **Hard limiter** to prevent distortion on output peaks
- **Built-in presets** (Flat, Bass Boost, Vocal Clarity, Treble Boost, and more)
- **Custom presets** — save and load your own EQ profiles
- **AutoEQ import** — import EqualizerAPO `ParametricEQ.txt` files from [AutoEQ](https://github.com/jaakkopasanen/AutoEq)
- **Independent device selection** for input and output
- **Persistent settings** — bands, volume, preamp, and device choices are saved across sessions

## Requirements

- macOS 14.0 (Sonoma) or later
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) virtual audio driver

## Installation

### 1. Install BlackHole 2ch

BlackHole is a free, open-source virtual audio driver that lets ParaEQ capture system audio.

**Via Homebrew (recommended):**

```bash
brew install blackhole-2ch
```

**Manual install:**

Download from [https://existential.audio/blackhole/](https://existential.audio/blackhole/) and follow their installation guide.

After installing, verify BlackHole appears in **System Settings > Sound** as an output device.

### 2. Build ParaEQ

```bash
git clone https://github.com/peterclarktech/ParaEQ.git
cd ParaEQ
bash build.sh
```

This compiles the app, creates a signed `.app` bundle, and places it at `.build/ParaEQ.app`.

### 3. Run

```bash
open .build/ParaEQ.app
```

On first launch, macOS will ask for **microphone/audio input permission** — this is required for ParaEQ to read audio from BlackHole. Grant the permission in **System Settings > Privacy & Security > Microphone**.

Optionally, copy the app to your Applications folder:

```bash
cp -r .build/ParaEQ.app /Applications/
```

## How It Works

ParaEQ uses a pure CoreAudio pipeline with three dedicated AudioUnits:

```
System Audio (Music, Browser, etc.)
         │
         ▼
   BlackHole 2ch          ← macOS routes system audio here
         │
         ▼
   Input AUHAL             ← captures audio from BlackHole
         │
         ▼
   Ring Buffer (stereo)
         │
         ▼
   NBandEQ AudioUnit       ← applies 10-band parametric EQ
         │
         ▼
   Output AUHAL            ← sends processed audio to headphones
         │
         ▼
   Headphones / Speakers
```

When you press **Start**, ParaEQ automatically sets your system output to BlackHole and routes processed audio to your selected output device. When you press **Stop**, your original system output is restored.

## Usage

1. Click the slider icon in the menu bar to open ParaEQ
2. Select **BlackHole 2ch** as input and your headphones/speakers as output
3. Press **Start** — system audio will now route through the EQ
4. Adjust bands by expanding them in the band list, or select a preset
5. Press **Stop** when done — system audio returns to normal

### Importing AutoEQ Profiles

ParaEQ can import EQ profiles from the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project:

1. Download a `ParametricEQ.txt` file for your headphones from AutoEQ
2. In ParaEQ, click **Import** and select the file
3. The profile is imported as a custom preset (truncated to 10 bands if needed)

### Presets

- **Built-in**: Flat, Bass Boost, Vocal Clarity, Treble Boost, T5p 2nd Harman, T5p 2nd Bass
- **Custom**: Save your current EQ settings with a name, delete when no longer needed

## Building from Source

Requires Xcode command-line tools with Swift 5.10+:

```bash
xcode-select --install   # if not already installed
bash build.sh
```

The build script creates a signed macOS app bundle. Code signing (ad-hoc) is required for macOS to grant audio input access.

## License

MIT
