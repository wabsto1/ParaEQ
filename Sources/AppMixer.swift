import CoreAudio
import Foundation
import Observation

/// One user-visible application in the mixer: an app-level grouping of HAL
/// process objects (an app may own several audio-producing processes).
struct AudioApp: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let objectIDs: [AudioObjectID]
    let isPlaying: Bool
}

/// Persisted per-app mixer state, keyed by bundle ID.
struct AppMixerSetting: Codable, Equatable {
    var gainDB: Float = 0      // -60 ... +6; <= -59.5 renders as -inf
    var muted: Bool = false

    var isNeutral: Bool { !muted && abs(gainDB) < 0.05 }
    var linearGain: Float {
        if muted || gainDB <= -59.5 { return 0 }
        return powf(10, gainDB / 20)
    }
}

/// What the engine must build a dedicated tap for: one adjusted app.
struct AppException: Equatable {
    let bundleID: String
    let objectIDs: [AudioObjectID]
    var gainLinear: Float
}

/// Mixer policy + state. Decides which apps need exception taps and when a
/// neutral app's tap may be reclaimed (grace period against slider wiggling).
/// Pure with respect to time — `now` is always a parameter — so every rule
/// is unit-testable. Engine/directory wiring is added in a later task.
@Observable
final class AppMixer {
    /// Fixed IOCtx gain slots; also the exception-tap cap.
    static let maxExceptions = 16
    /// How long a back-to-neutral app keeps its tap before teardown.
    static let graceSeconds: TimeInterval = 30

    private(set) var settings: [String: AppMixerSetting]
    /// bundleID → when its grace period ends (set on return to neutral).
    private var graceDeadlines: [String: Date] = [:]
    /// Adjustment order; keeps exception order stable across gain changes.
    private var adjustOrder: [String] = []

    init(settings: [String: AppMixerSetting] = [:]) {
        self.settings = settings
        adjustOrder = Array(settings.keys).sorted()
    }

    var slotsFull: Bool {
        settings.values.filter { !$0.isNeutral }.count >= Self.maxExceptions
    }

    func setting(for bundleID: String) -> AppMixerSetting {
        settings[bundleID] ?? AppMixerSetting()
    }

    func setGain(_ dB: Float, for bundleID: String) {
        var s = setting(for: bundleID)
        s.gainDB = min(max(dB, -60), 6)
        apply(s, for: bundleID)
    }

    func setMuted(_ on: Bool, for bundleID: String) {
        var s = setting(for: bundleID)
        s.muted = on
        apply(s, for: bundleID)
    }

    /// Remove the app's setting entirely (unpin); tap reclaimed immediately.
    func reset(_ bundleID: String) {
        settings[bundleID] = nil
        graceDeadlines[bundleID] = nil
        adjustOrder.removeAll { $0 == bundleID }
    }

    private func apply(_ s: AppMixerSetting, for bundleID: String) {
        settings[bundleID] = s
        if !adjustOrder.contains(bundleID) { adjustOrder.append(bundleID) }
        if s.isNeutral {
            if graceDeadlines[bundleID] == nil {
                graceDeadlines[bundleID] = Date().addingTimeInterval(Self.graceSeconds)
            }
        } else {
            graceDeadlines[bundleID] = nil
        }
    }

    /// The exceptions the engine should have right now. Order follows first
    /// adjustment, so it is stable across gain changes (gain-only updates
    /// must not trigger an engine restart).
    ///
    /// Two-pass priority: non-neutral (actually adjusted) apps always claim a
    /// slot first, in `adjustOrder`; grace holdovers (neutral apps still
    /// inside their teardown window) fill only the slots left over. This
    /// keeps the cap consistent with `slotsFull` — a fresh adjustment can be
    /// dropped only when 16 OTHER non-neutral adjustments already exist,
    /// never preempted by an old app coasting through its grace period.
    func desiredExceptions(apps: [AudioApp], now: Date) -> [AppException] {
        func exception(for bundleID: String) -> AppException? {
            guard let s = settings[bundleID],
                  let app = apps.first(where: { $0.bundleID == bundleID })
            else { return nil }
            return AppException(
                bundleID: bundleID, objectIDs: app.objectIDs,
                gainLinear: s.linearGain)
        }

        var result: [AppException] = []
        for bundleID in adjustOrder {
            guard result.count < Self.maxExceptions,
                  let s = settings[bundleID], !s.isNeutral,
                  let ex = exception(for: bundleID)
            else { continue }
            result.append(ex)
        }
        for bundleID in adjustOrder {
            guard result.count < Self.maxExceptions,
                  let s = settings[bundleID], s.isNeutral,
                  let deadline = graceDeadlines[bundleID], now < deadline,
                  let ex = exception(for: bundleID)
            else { continue }
            result.append(ex)
        }
        return result
    }

    /// Earliest pending grace deadline (for scheduling a resync).
    func nextGraceDeadline(now: Date) -> Date? {
        graceDeadlines.values.filter { $0 > now }.min()
    }
}
