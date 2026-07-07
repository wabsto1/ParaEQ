// MultiTapSpike — proves: (a) two taps in one aggregate arrive as separate
// input buffers in tap-list order; (b) a per-process tap .mutedWhenTapped
// silences that process at the speaker while the global tap keeps flowing.
//
// Run:  afplay /System/Library/Sounds/Submarine.aiff  in a loop in another
// terminal, then run this. It taps afplay by PID.
//
// Build: swiftc -o /tmp/multitapspike Prototypes/MultiTapSpike/main.swift \
//          -framework CoreAudio -framework AudioToolbox
// Logs to stdout + ~/Library/Logs/MultiTapSpike.log. Runs 20 s, cleans up.

import AudioToolbox
import CoreAudio
import Foundation

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/MultiTapSpike.log")
func log(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    print(line, terminator: "")
    if let d = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else { try? d.write(to: logURL) }
    }
}

func check(_ s: OSStatus, _ what: String) {
    guard s != noErr else { return }
    log("FAIL \(what): \(s)"); exit(1)
}

func processObject(forPID pid: pid_t) -> AudioObjectID {
    var pid = pid
    var obj = AudioObjectID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    check(AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr,
        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj),
        "TranslatePIDToProcessObject(\(pid))")
    return obj
}

// -- 1. Find afplay ----------------------------------------------------------
let ps = Process()
ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
ps.arguments = ["-n", "afplay"]
let pipe = Pipe(); ps.standardOutput = pipe
try! ps.run(); ps.waitUntilExit()
guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                       encoding: .utf8),
      let afplayPID = pid_t(out.trimmingCharacters(in: .whitespacesAndNewlines))
else {
    log("No afplay running. Start:  while true; do afplay /System/Library/Sounds/Submarine.aiff; done")
    exit(1)
}
log("Target afplay pid=\(afplayPID)")
let afplayObj = processObject(forPID: afplayPID)
let selfObj = processObject(forPID: pid_t(ProcessInfo.processInfo.processIdentifier))

// -- 2. Two taps: global (excludes self + afplay), and afplay-only ----------
let globalDesc = CATapDescription(
    stereoGlobalTapButExcludeProcesses: [selfObj, afplayObj])
globalDesc.uuid = UUID(); globalDesc.name = "Spike Global"
globalDesc.isPrivate = true
globalDesc.muteBehavior = .mutedWhenTapped
var globalTap = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(globalDesc, &globalTap), "create global tap")

let appDesc = CATapDescription(stereoMixdownOfProcesses: [afplayObj])
appDesc.uuid = UUID(); appDesc.name = "Spike afplay"
appDesc.isPrivate = true
appDesc.muteBehavior = .mutedWhenTapped
var appTap = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(appDesc, &appTap), "create app tap")
log("Taps: global #\(globalTap) app #\(appTap)")

// -- 3. Aggregate: default output + BOTH taps (global first) ----------------
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var outDev = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                 &addr, 0, nil, &size, &outDev), "default output")
addr.mSelector = kAudioDevicePropertyDeviceUID
var uidCF: CFString = "" as CFString
size = UInt32(MemoryLayout<CFString>.size)
check(AudioObjectGetPropertyData(outDev, &addr, 0, nil, &size, &uidCF), "output UID")
let outputUID = uidCF as String

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Spike Aggregate",
    kAudioAggregateDeviceUIDKey: "com.paraeq.spike." + UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: globalDesc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey: true],
        [kAudioSubTapUIDKey: appDesc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey: true],
    ],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "create aggregate")
log("Aggregate #\(aggID)")

// -- 4. IOProc: log buffer layout + per-pair RMS; pass app tap to output ----
final class Stats {
    var callbacks: UInt64 = 0
    var described = false
    var rms = [Float](repeating: 0, count: 8)   // per input buffer
}
let stats = Stats()
var procID: AudioDeviceIOProcID?
let q = DispatchQueue(label: "spike.io", qos: .userInteractive)
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) {
    _, inData, _, outData, _ in
    stats.callbacks &+= 1
    let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    if !stats.described {
        stats.described = true
        // Not realtime-safe; once, for diagnostics only.
        var layout = "input buffers: "
        for (i, b) in inABL.enumerated() {
            layout += "[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)  "
        }
        print(layout)
    }
    for (i, buf) in inABL.enumerated() where i < 8 {
        guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = Int(buf.mDataByteSize) / 4
        var acc: Float = 0
        for f in 0..<n { acc += data[f] * data[f] }
        let r = n > 0 ? (acc / Float(n)).squareRoot() : 0
        if r > stats.rms[i] { stats.rms[i] = r }
    }
    // Pass ONLY the app tap (buffers after the global pair) to the output —
    // audible proof the second stream is afplay: you hear afplay, nothing else.
    let outABL = UnsafeMutableAudioBufferListPointer(outData)
    var globalChannels = 0
    var appL: UnsafeMutablePointer<Float>?
    var appR: UnsafeMutablePointer<Float>?
    var appFrames = 0
    var channel = 0
    for buf in inABL {
        let n = max(Int(buf.mNumberChannels), 1)
        guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(buf.mDataByteSize) / (n * 4)
        for ch in 0..<n {
            if channel == 0 || channel == 1 { globalChannels += 1 }
            if channel == 2 || channel == 3 {
                // stash pointers by striding — planar vs interleaved both work
                if channel == 2 { appL = data + ch; appFrames = frames }
                if channel == 3 { appR = data + ch }
                _ = n
            }
            channel += 1
        }
    }
    _ = globalChannels
    for buf in outABL {
        let n = max(Int(buf.mNumberChannels), 1)
        guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(buf.mDataByteSize) / (n * 4)
        for f in 0..<frames {
            for ch in 0..<n {
                // NOTE: stride of the app buffer is its own channel count; the
                // spike only handles the planar (stride 1) and stereo-
                // interleaved (stride 2) cases we expect to see.
                let src: Float
                if let l = appL, let r = appR, f < appFrames {
                    src = ch % 2 == 0 ? l[f * 2] : r[f * 2]     // interleaved guess
                } else if let l = appL, f < appFrames {
                    src = l[f]                                   // planar mono/first
                } else { src = 0 }
                data[f * n + ch] = src
            }
        }
    }
}, "create IOProc")
check(AudioDeviceStart(aggID, procID), "start")
log("Running 20 s. EXPECT: afplay audible (via our reroute), other apps' audio")
log("audible normally is WRONG (global tap not muting) — should be silent if")
log("you play e.g. Music, since we don't forward the global pair.")

DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    AudioDeviceStop(aggID, procID)
    if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(appTap)
    AudioHardwareDestroyProcessTap(globalTap)
    log("callbacks=\(stats.callbacks)")
    log("peak RMS per input buffer: \(stats.rms.prefix(4).map { String(format: "%.4f", $0) })")
    log("VERDICT: buffer[≥2 or second pair] RMS > 0 with afplay playing = per-process tap works")
    exit(0)
}
RunLoop.main.run()
