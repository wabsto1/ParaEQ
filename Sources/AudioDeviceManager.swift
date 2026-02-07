import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum AudioDeviceManager {

    static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { buildDevice($0) }
    }

    static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput }
    }

    static func findBlackHole() -> AudioDevice? {
        inputDevices().first { $0.name.lowercased().contains("blackhole") }
    }

    /// Best guess for the real output device (not BlackHole, not aggregate)
    static func preferredOutputDevice() -> AudioDevice? {
        let outputs = outputDevices().filter {
            let n = $0.name.lowercased()
            return !n.contains("blackhole") && !n.contains("aggregate")
        }
        return outputs.first { $0.name.lowercased().contains("headphone") }
            ?? outputs.first
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        ) == noErr
    }

    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr
        else { return nil }
        return rate
    }

    @discardableResult
    static func setNominalSampleRate(_ deviceID: AudioDeviceID, rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(rate)
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &rate
        ) == noErr
    }

    // MARK: - Private helpers

    private static func buildDevice(_ deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
              let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
        else { return nil }

        let inp = channelCount(deviceID, scope: kAudioObjectPropertyScopeInput) > 0
        let out = channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput) > 0
        return AudioDevice(id: deviceID, name: name, uid: uid, hasInput: inp, hasOutput: out)
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = result?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    private static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bytes.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bytes) == noErr
        else { return 0 }

        let abl = bytes.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
