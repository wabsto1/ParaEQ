import AppKit
import CoreAudio
import Foundation

// List HAL process objects: pid, bundleID, isRunningOutput
func data<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = def
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr else { return def }
    return v
}
func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr else { return "" }
    return cf as String
}
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procs)
for p in procs {
    let pid = data(p, kAudioProcessPropertyPID, pid_t(-1))
    let bid = str(p, kAudioProcessPropertyBundleID)
    let running = data(p, kAudioProcessPropertyIsRunningOutput, UInt32(0))
    let name = pid > 0 ? (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "") : ""
    print("\(running == 1 ? "PLAYING" : "       ") pid=\(pid) [\(bid)] \(name)")
}
