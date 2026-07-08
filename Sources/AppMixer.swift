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

    @ObservationIgnored private weak var engine: AudioEngine?
    @ObservationIgnored private(set) var directory: AppAudioDirectory?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var graceWork: DispatchWorkItem?
    private static let defaultsKey = "paraeq.appMixer"

    init(settings: [String: AppMixerSetting] = [:]) {
        self.settings = settings
        adjustOrder = Array(settings.keys).sorted()
    }

    convenience init(engine: AudioEngine?, directory: AppAudioDirectory?) {
        var loaded: [String: AppMixerSetting] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(
               [String: AppMixerSetting].self, from: data) {
            loaded = saved
        }
        self.init(settings: loaded)
        self.engine = engine
        self.directory = directory
        directory?.start()
        sync()
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
        sync()
    }

    func setMuted(_ on: Bool, for bundleID: String) {
        var s = setting(for: bundleID)
        s.muted = on
        apply(s, for: bundleID)
        sync()
    }

    /// Remove the app's setting entirely (unpin); tap reclaimed immediately.
    func reset(_ bundleID: String) {
        settings[bundleID] = nil
        graceDeadlines[bundleID] = nil
        adjustOrder.removeAll { $0 == bundleID }
        sync()
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
    /// must not trigger an engine restart) — and stable across a non-neutral
    /// app transitioning into (or out of) its grace period, as long as
    /// membership in the returned set doesn't change; only actual
    /// membership changes (add/drop) may reorder the list.
    ///
    /// Two-pass priority, membership only: non-neutral (actually adjusted)
    /// apps always claim a slot first, in `adjustOrder`; grace holdovers
    /// (neutral apps still inside their teardown window) fill only the
    /// slots left over. This keeps the cap consistent with `slotsFull` — a
    /// fresh adjustment can be dropped only when 16 OTHER non-neutral
    /// adjustments already exist, never preempted by an old app coasting
    /// through its grace period. Once membership is decided, the returned
    /// array is built with a single walk over `adjustOrder`, so relative
    /// order is preserved for every app whose membership didn't change.
    func desiredExceptions(apps: [AudioApp], now: Date) -> [AppException] {
        func exception(for bundleID: String) -> AppException? {
            guard let s = settings[bundleID],
                  let app = apps.first(where: { $0.bundleID == bundleID })
            else { return nil }
            return AppException(
                bundleID: bundleID, objectIDs: app.objectIDs,
                gainLinear: s.linearGain)
        }

        var members: Set<String> = []
        for bundleID in adjustOrder {
            guard members.count < Self.maxExceptions,
                  let s = settings[bundleID], !s.isNeutral
            else { continue }
            members.insert(bundleID)
        }
        for bundleID in adjustOrder {
            guard members.count < Self.maxExceptions,
                  let s = settings[bundleID], s.isNeutral,
                  let deadline = graceDeadlines[bundleID], now < deadline
            else { continue }
            members.insert(bundleID)
        }

        var result: [AppException] = []
        for bundleID in adjustOrder {
            guard members.contains(bundleID), let ex = exception(for: bundleID)
            else { continue }
            result.append(ex)
        }
        return result
    }

    /// Earliest pending grace deadline (for scheduling a resync).
    func nextGraceDeadline(now: Date) -> Date? {
        graceDeadlines.values.filter { $0 > now }.min()
    }

    // MARK: - Wiring: engine sync, persistence, display list

    /// Rows for the UI: running audio apps first (directory order), then
    /// pinned apps (adjusted but not currently running) as placeholders.
    var displayApps: [AudioApp] {
        let running = directory?.apps ?? []
        let runningIDs = Set(running.map(\.bundleID))
        let pinned = settings.keys
            .filter { !runningIDs.contains($0) }
            .sorted()
            .map { AudioApp(bundleID: $0, name: displayName(for: $0),
                            objectIDs: [], isPlaying: false) }
        return running + pinned
    }

    private func displayName(for bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// Directory changed (apps appeared/vanished, playback state flipped).
    func appsChanged() { sync() }

    /// Recompute desired exceptions and push to the engine; reschedule the
    /// grace-expiry resync.
    private func sync() {
        let now = Date()
        let apps = directory?.apps ?? []
        engine?.setAppExceptions(desiredExceptions(apps: apps, now: now))
        graceWork?.cancel()
        if let deadline = nextGraceDeadline(now: now) {
            let work = DispatchWorkItem { [weak self] in self?.sync() }
            graceWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + deadline.timeIntervalSince(now) + 0.5,
                execute: work)
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePendingNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func savePendingNow() {
        saveWork?.cancel()
        if settings.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
