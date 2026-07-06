# ParaEQ

System-wide macOS parametric EQ. Menu-bar SwiftUI app over a pure
CoreAudio/Accelerate engine — no external dependencies.

## Commands

- Build app bundle: `bash build.sh` → `.build/ParaEQ.app` (signed; required for TCC)
- Tests: `swift test` (52 DSP/parser/logic tests, no audio hardware needed)
- Deploy: `ditto .build/ParaEQ.app /Applications/ParaEQ.app` (then relaunch)
- Live diagnostics: `~/Library/Logs/ParaEQ.log` (status line every 10 s while running)

## Architecture

Core Audio process tap (`.mutedWhenTapped`, own PID excluded) → private
aggregate device (real output = main sub-device) → single IOProc:
stage → [M/S] → vDSP biquad cascades → FIR (GraphicEQ/IR) → crossfeed →
balance/volume → lookahead limiter → output. See `docs/ARCHITECTURE.md`,
including the **Hard-won platform gotchas** section before touching
listener/teardown/aggregate code.

## Rules

- IO callback: no allocation, no locks, no Swift array assignment into
  long-lived storage (COW allocates).
- HAL property listeners must stay on `listenerQueue`, never `.main`
  (documented deadlock).
- Every DSP change gets a unit test; verify live via the log after engine changes.
- Signing: `build.sh` prefers the "ParaEQ Dev Signing" keychain identity so the
  System Audio Recording TCC grant survives rebuilds. Don't switch to plain
  ad-hoc signing.
- macOS 14.4+ APIs are assumed (`Package.swift` platform); macOS 26 requires a
  non-nil dispatch queue for `AudioDeviceCreateIOProcIDWithBlock`.
