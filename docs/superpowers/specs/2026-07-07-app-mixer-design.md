# App Mixer — Design

Date: 2026-07-07
Status: Approved

## Goal

Per-application volume control (Windows-style volume mixer) for system audio,
built on Core Audio process taps. v1 is **volume + mute only**; per-app EQ is a
deliberate future extension on the same mechanism.

## Scope decisions (user-approved)

- **v1 controls:** per-app gain slider (−∞…+6 dB) and mute. No solo, no per-app EQ.
- **App list:** apps *currently playing audio* (HAL `isRunningOutput`), grouped
  by application; apps the user has adjusted stay pinned even when silent.
- **UI placement:** collapsible section in the existing menu-bar panel (and
  therefore the pop-out window), collapsed by default.
- **Architecture:** global tap + exception taps (Approach B below).

## Architecture

### Why exception taps

The existing engine uses one global process tap (`stereoGlobalTapButExcludeProcesses`,
`AudioEngine.swift`) which delivers a single pre-summed mix — it cannot be
un-mixed per app. Per-app gain requires tapping specific process objects with
`.mutedWhenTapped` (mute at source, re-inject at adjusted gain).

Two candidate shapes:

- **A. Tap-per-app for everything** — uniform, but taps/streams churn on every
  app audio start/stop (each aggregate reconfiguration risks the documented
  stalled-aggregate gotcha), and a newly launched audio process plays untapped
  (unmuted, un-EQ'd, doubled) until noticed.
- **B. Global tap + exception taps (chosen)** — untouched apps stay on the
  proven global path forever. Only when the user adjusts an app away from
  0 dB/unmuted does it get its own tap. Reconfiguration happens only on
  explicit user action, not app-lifecycle churn.

### Data flow

```
App A ──┐                                      (untouched apps)
App B ──┤── global tap (excludes: us, X, Y) ──┐
App C ──┘                                      ├─ sum ─ stage ─ [M/S] ─ EQ ─ FIR ─
App X ──── exception tap ── ×gainX ───────────┤        crossfeed ─ bal/vol ─ limiter ─ out
App Y ──── exception tap ── ×gainY ───────────┘
```

Per-app streams are summed **before** the existing DSP chain, so excepted apps
still receive full EQ/limiter treatment. All taps live in the same aggregate,
so streams share the aggregate clock and arrive sample-aligned in one IOProc.

### Exception lifecycle

Adjusting app X for the first time:

1. Resolve X's HAL process objects — every process whose bundle ID or
   responsible PID (helpers, e.g. Chrome renderers) belongs to X.
2. Create a per-process tap for those objects, `.mutedWhenTapped`, format
   matching the global tap.
3. Add X's PIDs to the global tap's exclusion list via a live update of
   `kAudioTapPropertyDescription` (see Spike). Fallback: recreate the global
   tap, prepare-then-swap so audio never doubles.
4. Add the tap to the aggregate's tap list → new input stream in the IOProc.
5. IOProc computes `output = globalStream + Σ (gain_i × appStream_i)`.

Returning X to 0 dB/unmuted starts a **~30 s grace timer** before teardown
(avoids reconfig thrash from slider wiggling). Hard cap: **16 concurrent
exception taps** (fixed preallocated IOCtx slots); further adjustments are
refused with a UI notice.

### Realtime rules (unchanged)

Per-app gains live in preallocated `IOCtx` storage (`appGain[16]`), written
with atomics from the UI thread. No allocation, no locks, no Swift COW
assignment in the IO callback.

## Components

| Unit | Responsibility |
| --- | --- |
| `Sources/AppAudioDirectory.swift` | Process discovery only. HAL process-object list + `isRunningOutput` listeners (on `listenerQueue`, never `.main`), grouping by bundle ID / responsible PID, name+icon via `NSRunningApplication`. Publishes an observable `[AudioApp]` (bundleID, name, icon, isPlaying, pids), debounced to main. Knows nothing about taps or gain. |
| `Sources/AppMixer.swift` | Policy + state. Per-bundle-ID gain/mute table (persisted), decides when an app needs an exception tap and when to reclaim (grace expiry, slot cap), drives `AudioEngine`. Decision logic is pure/unit-testable. |
| `AudioEngine` additions | The only HAL-touching code: `addExceptionTap(pids:) -> slot`, `removeExceptionTap(slot:)`, global-exclusion update, IOProc multi-stream sum with per-slot gain. |
| `Sources/AppMixerView.swift` | Collapsible panel section. Row = icon, name, gain slider, mute; pinned rows show a "not playing" state with ✕ to reset. Per-tick state (playing indicators) read only in leaf row views (panel-performance rule). |

Persistence: per-bundle-ID gain/mute in the existing saved-state file;
reapplied when a matching app starts playing after launch.

## Edge cases & error handling

- **Excepted app quits:** tear down its tap; keep stored gain; re-arm on
  relaunch via the process-list listener.
- **Reconfig failure / stall watchdog:** fail toward *audio always plays* —
  drop all exceptions, restore the plain global tap, log + UI note ("mixer
  reset"). Never leave an app muted at source without its re-injection stream.
- **New helper PID for an excepted app:** re-resolve the group; add the PID to
  the exception tap first, then the exclusion list (worst case is brief
  doubling, never silence).
- **Sleep/wake, output-device switch:** exceptions rebuilt inside the existing
  `restart()` path.

## Spike (before implementation)

A throwaway prototype in `Prototypes/` must prove, in order:

1. `kAudioTapPropertyDescription` is live-settable (exclusion-list update
   without recreating the tap). Fallback: recreate-and-swap.
2. Multiple taps in one aggregate deliver sample-aligned separate input
   streams to a single IOProc.
3. `.mutedWhenTapped` on a per-process tap actually silences that app at the
   hardware output while the global tap continues.

If (2) fails: fallback architecture is one IOProc per exception tap writing
into a lock-free ring consumed by the main IOProc (more code, still viable).

## Testing

- **Unit (no hardware):** AppMixer policy — slot allocation/exhaustion, grace
  reclaim, needs-exception decisions, persistence round-trip, PID-group
  diffing when helpers appear/vanish.
- **DSP:** multi-stream sum + per-slot gain over synthetic buffers.
- **Live:** log status line gains `apps=N` (exception count); verify
  `callbacks=` keeps increasing after every reconfig; manual check that
  adjusting one app leaves others untouched.

## Future (explicitly out of scope for v1)

- Per-app EQ (insert a per-slot biquad cascade before the sum — the exception
  mechanism already isolates the stream).
- Solo; per-app output-device routing; "switch preset on frontmost app"
  super-preset (reuses `AppAudioDirectory`).
