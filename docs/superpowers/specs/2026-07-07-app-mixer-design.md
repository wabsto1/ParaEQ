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

## Spike findings (2026-07-07)

Ran `Prototypes/MultiTapSpike/main.swift` per the task-1 brief. ParaEQ was not
running (verified with `pgrep -x ParaEQ` beforehand, so no teardown needed).
Two runs: first against a normal `while true; do afplay Submarine.aiff; done`
loop (rejected — see surprises below), then against a single long-lived
`afplay -r 0.04 Submarine.aiff` process (~30 s) so the tapped PID stayed
alive for the whole 20 s measurement window. Both builds compiled clean
(one pre-existing warning at the `uidCF` cast, present in the brief's own
code, harmless). Both runs: `AudioHardwareCreateProcessTap` and
`AudioHardwareCreateAggregateDevice` succeeded with no error, IOProc ran
(`callbacks=1959`–`1962` over 20 s, i.e. ~98 Hz / ~512-frame blocks at 48 kHz
— healthy and not stalled), and cleanup completed without error.

1. **Buffer layout / order**: input ABL had exactly 2 `AudioBuffer`s, both
   `ch=2 bytes=4096` (1024 float32 samples = 512 interleaved stereo frames).
   That is one interleaved-stereo buffer per tap — consistent in *count and
   shape* with "global tap first, app tap second" per
   `kAudioAggregateDeviceTapListKey` order. However, **this could not be
   confirmed by content**, only by shape: neither buffer carried any nonzero
   samples in either run (see finding 3), so there was no signal to use to
   verify buffer[1] was actually the afplay stream. Buffer *count* matches
   the plan's assumption (global first, then one stereo pair per exception
   tap); buffer *identity* is unverified.
2. **Frame counts**: identical across both taps' buffers in every callback —
   both buffers were always `n=1024` (512 frames), never mismatched, across
   ~1960 callbacks in each run.
3. **`.mutedWhenTapped` silencing afplay at the speaker**: **could not be
   verified**. Both input buffers were pure zeros for the entire 20 s in
   both runs (peak RMS `0.0000` on all logged slots; added temporary debug
   logging of raw samples every 500 callbacks — `maxAbs=0.0`, `first4=[0.0,
   0.0, 0.0, 0.0]` throughout). Since capture was silent, there was no
   afplay audio in the tap to reroute to the output, so the audible
   before/after check the brief describes could not be exercised either way.
4. **Errors/oddities**: no `check()` failures, no tap-creation error, no
   format-mismatch — everything that returns an `OSStatus` returned `noErr`.
   The failure mode is a **silent zero-signal capture with a fully healthy
   IOProc**, not a crash or explicit error. Suspected root cause: the
   process invoking the spike binary is a subprocess of the `claude` CLI
   (headless, `ps` shows parent chain `zsh → claude --dangerously-skip-permissions`),
   not a GUI terminal app (Terminal.app/iTerm2) that macOS TCC recognizes as
   a "responsible process" capable of receiving/completing a System Audio
   Recording consent prompt. `log show --predicate 'process == "coreaudiod"'`
   and TCC-subsystem log queries over the run window show **zero** matching
   entries — no prompt was even generated, consistent with the request being
   silently dropped rather than denied-with-a-dialog. The TCC database itself
   couldn't be queried directly (`TCC.db` open returns "authorization
   denied" even for the owning user, as expected by SIP). A second, separate
   surprise: the brief's literal `while true; do afplay ...; done` loop
   respawns a new `afplay` process (new PID) roughly every 1.5 s because
   `Submarine.aiff` is only ~1.49 s long (`afinfo`), while spike setup
   (tap/aggregate/IOProc creation) happens once against the PID pgrep found
   at start — that PID's process can exit before or shortly after the 20 s
   capture begins. Worked around this by playing a single slowed-down
   instance (`afplay -r 0.04 Submarine.aiff`, ~30 s runtime) so one stable
   PID lived through the whole window; this did not change the zero-signal
   result, so the TCC explanation above is a better fit than the respawn
   timing issue (which was real but not the actual blocker here).

**Verdict (superseded — see re-run below)**: the 2026-07-07 evening runs
were blocked by a machine-wide coreaudiod tap-subsystem wedge (production
ParaEQ was also stalled at callbacks=0; 11-day uptime; eqMac's HAL driver
installed). A reboot + eqMac driver removal cleared it.

## Spike re-run findings (2026-07-08, post-reboot) — SUCCESS

Re-ran the same binary, launched via Terminal.app (`osascript … do script`)
so TCC attributes System Audio Recording correctly; headless launches from
the CLI process tree still capture silence — a permanent constraint for any
future automated audio verification. Three runs, all `callbacks≈1963` over
20 s. The third run used an instrumented build (per-second RMS time series
per buffer) with ParaEQ quit, one long-lived `afplay -r 0.04 Submarine`
(tapped + excluded) and a `say` burst from a second process at t≈10 s:

1. **Buffer order confirmed by content**: the `say` burst appears ONLY in
   buffer[0] (global tap) at t=11–15 s; buffer[1] carries only the slowed
   submarine's decaying envelope (0.10 → 0.0003 monotonic). Global tap
   first, one stereo pair per exception tap, in tap-list order — as the
   plan assumes.
2. **Per-process capture confirmed**: buffer[1] peak RMS 0.136–0.139 with
   afplay playing (was 0.0000 pre-reboot).
3. **Global-tap exclusion confirmed**: buffer[0] does not track buffer[1]'s
   envelope (t=7–8 s: buf0 0.016–0.020 << buf1 0.042–0.064) — afplay does
   not leak into the global pair at any gain. Sporadic buffer[0] transients
   (~0.5 RMS) are other system audio, which is exactly what a global tap
   carries on a live desktop.
4. **`.mutedWhenTapped` at-speaker mute for the per-process tap**: not
   audibly isolated by these runs (production ParaEQ proves the behavior
   for global taps daily); to be confirmed end-to-end in Task 8 live
   verification.

Both load-bearing claims (a) buffer order/layout and (b) per-process
capture with global-pair exclusion are **verified by content**. Task 1
complete; Task 4 may rely on the two-buffer interleaved-stereo layout.
