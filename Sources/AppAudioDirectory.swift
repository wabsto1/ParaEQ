import AppKit
import CoreAudio
import Foundation
import Observation

/// The process responsible for another (e.g. Chrome for its renderer
/// helpers). Private-but-stable libquarantine call used by audio-capture
/// tools; falls back to the process's own pid on failure.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Discovers which applications currently produce audio, via the HAL's
/// process-object list. Grouping: helper processes roll up under their
/// responsible application. Listeners live on their own dispatch queue
/// (never .main — documented deadlock); results publish on the main thread.
@Observable
final class AppAudioDirectory {
    private(set) var apps: [AudioApp] = []
    private(set) var generation = 0

    @ObservationIgnored
    private let queue = DispatchQueue(label: "com.paraeq.appdirectory")
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    /// Process objects we have an isRunningOutput listener on.
    @ObservationIgnored private var listened: Set<AudioObjectID> = []

    struct ProcessSnapshot: Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    // MARK: - Pure grouping

    /// Groups process snapshots into user-visible apps. `resolve` maps
    /// (pid, bundleID) → (group key, display name) — production uses the
    /// responsible-app lookup; tests inject a fake. Returns apps sorted
    /// playing-first, then by name; objectIDs sorted for stable equality.
    static func group(
        _ snapshots: [ProcessSnapshot],
        resolve: (pid_t, String) -> (key: String, name: String)?
    ) -> [AudioApp] {
        var byKey: [String: (name: String, objects: [AudioObjectID], playing: Bool)] = [:]
        for s in snapshots {
            guard let (key, name) = resolve(s.pid, s.bundleID) else { continue }
            var e = byKey[key] ?? (name, [], false)
            e.objects.append(s.objectID)
            e.playing = e.playing || s.isRunningOutput
            byKey[key] = e
        }
        return byKey
            .map { AudioApp(bundleID: $0.key, name: $0.value.name,
                            objectIDs: $0.value.objects.sorted(),
                            isPlaying: $0.value.playing) }
            .sorted {
                if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Production resolver: responsible app via NSRunningApplication.
    static func resolveApp(pid: pid_t, bundleID: String) -> (key: String, name: String)? {
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        let ownerPID = responsible > 0 ? responsible : pid
        if let app = NSRunningApplication(processIdentifier: ownerPID),
           let key = app.bundleIdentifier {
            return (key, app.localizedName ?? key)
        }
        guard !bundleID.isEmpty else { return nil }
        return (bundleID, bundleID.components(separatedBy: ".").last ?? bundleID)
    }

    // MARK: - HAL wiring

    func start() {
        guard !started else { return }
        started = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in self?.scheduleRefresh() }
        scheduleRefresh()
    }

    /// Debounce: process lists churn in bursts (app launch spawns helpers).
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Runs on `queue`. Snapshots the HAL, groups, publishes on main.
    private func refresh() {
        let objects = Self.processObjectList()
        var snapshots: [ProcessSnapshot] = []
        for obj in objects {
            let pid = Self.pid(of: obj)
            guard pid > 0, pid != pid_t(ProcessInfo.processInfo.processIdentifier)
            else { continue }
            snapshots.append(ProcessSnapshot(
                objectID: obj, pid: pid,
                bundleID: Self.bundleID(of: obj),
                isRunningOutput: Self.isRunningOutput(obj)))
            if !listened.contains(obj) {
                listened.insert(obj)
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(obj, &addr, queue) {
                    [weak self] _, _ in self?.scheduleRefresh()
                }
            }
        }
        listened.formIntersection(objects)
        let grouped = Self.group(snapshots, resolve: Self.resolveApp)
        DispatchQueue.main.async { [weak self] in
            guard let self, grouped != self.apps else { return }
            self.apps = grouped
            self.generation &+= 1
        }
    }

    // MARK: - HAL property reads (on `queue`, never the IO thread)

    private static func processObjectList() -> Set<AudioObjectID> {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var list = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !list.isEmpty, AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr
        else { return [] }
        return Set(list)
    }

    private static func pid(of obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return value
    }

    private static func bundleID(of obj: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return value as String
    }

    private static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return value != 0
    }
}
