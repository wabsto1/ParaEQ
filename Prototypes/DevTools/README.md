# DevTools — live-verification helpers (2026-07-07)

Throwaway CLIs used to live-verify the App Mixer; kept because they are
generally useful for tap/HAL debugging (see ARCHITECTURE gotchas 10–15).

- `lsaudio.swift` — lists every HAL process object (pid, bundleID, name) and
  whether it `isRunningOutput`. Ground truth for "which app does coreaudiod
  think is playing"; no TCC needed (property reads only).
  Build: `swiftc -o /tmp/lsaudio lsaudio.swift -framework CoreAudio -framework AppKit`
- `drag.swift` — synthesizes a CGEvent left-mouse drag (`drag x0 y x1`).
  The only way to drive SwiftUI sliders programmatically (they ignore
  AXValue writes); use on the pop-out window, never the MenuBarExtra panel
  (gotcha 15). Needs Accessibility permission for the invoking terminal.
  Build: `swiftc -o /tmp/dragtool drag.swift`
