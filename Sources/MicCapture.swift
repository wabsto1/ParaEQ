import CoreAudio
import Foundation

// MARK: - Mono ring buffer (single realtime writer, UI-thread reader)
//
// Same discipline as SpectrumTap's rings: plain stores through pre-allocated
// pointers, no locks. A snapshot can tear by one callback at the seam, which
// is irrelevant for RMS measurement over seconds of audio.

final class MonoRing {
    let capacity: Int
    let sampleRate: Double
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writePtr: UnsafeMutablePointer<Int>

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        var cap = 1
        while cap < Int(seconds * sampleRate) { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        buffer = .allocate(capacity: cap)
        buffer.initialize(repeating: 0, count: cap)
        writePtr = .allocate(capacity: 1)
        writePtr.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        writePtr.deallocate()
    }

    /// Realtime-safe. Stores `frames` samples read at `data[0], data[stride],
    /// …` (stride = channel count for interleaved input, 1 for planar).
    func write(_ data: UnsafePointer<Float>, stride: Int, frames: Int) {
        var idx = writePtr.pointee
        for f in 0..<frames {
            buffer[idx & mask] = data[f * stride]
            idx &+= 1
        }
        writePtr.pointee = idx
    }

    /// The most recent `seconds` of audio in chronological order (UI thread).
    func snapshot(seconds: Double) -> [Float] {
        let idx = writePtr.pointee
        let n = min(Int(seconds * sampleRate), capacity, idx)
        var out = [Float](repeating: 0, count: n)
        let start = idx - n
        for i in 0..<n { out[i] = buffer[(start + i) & mask] }
        return out
    }

    /// RMS of the most recent `seconds` (live meter display).
    func levelRMS(seconds: Double) -> Float {
        let idx = writePtr.pointee
        let n = min(Int(seconds * sampleRate), capacity, idx)
        guard n > 0 else { return 0 }
        var sum = 0.0
        let start = idx - n
        for i in 0..<n {
            let s = Double(buffer[(start + i) & mask])
            sum += s * s
        }
        return Float((sum / Double(n)).squareRoot())
    }
}

// MARK: - Microphone capture (raw HAL input IOProc)
//
// Deliberately raw CoreAudio rather than AVCaptureSession/VoiceProcessingIO:
// the calibration needs the mic signal without voice isolation, AGC, or echo
// cancellation coloring the level. First AudioDeviceStart triggers the
// system microphone-permission prompt (NSMicrophoneUsageDescription).

final class MicCapture {
    let deviceID: AudioObjectID
    let deviceName: String
    let sampleRate: Double
    private let ring: MonoRing
    /// Mix-down staging for the IO callback (preallocated; no allocation
    /// on the IO thread).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 8_192
    private var procID: AudioDeviceIOProcID?
    // macOS 26 requires a non-nil queue; nil silently registers no IOProc.
    private let ioQueue = DispatchQueue(label: "com.paraeq.mic-io",
                                        qos: .userInteractive)
    private(set) var isRunning = false

    /// Binds to the current default input device; nil if there is none.
    init?() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        deviceID = device

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &nameAddr, 0, nil,
                                      &nameSize, &cfName) == noErr,
           let cf = cfName?.takeRetainedValue() {
            deviceName = cf as String
        } else {
            deviceName = "Microphone"
        }

        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &rateAddr, 0, nil,
                                         &rateSize, &rate) == noErr, rate > 0
        else { return nil }
        sampleRate = rate

        ring = MonoRing(seconds: 10, sampleRate: rate)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func start() throws {
        guard !isRunning else { return }
        let ring = self.ring
        let scratch = self.scratch
        let scratchCapacity = self.scratchCapacity
        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, ioQueue) {
            _, inInputData, _, _, _ in
            // Average every channel of every input buffer (MacBooks expose
            // a 3-mic array): spatial averaging over the mic positions makes
            // the earcup measurement less sensitive to exact placement.
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            var frames = 0
            var totalChannels = 0
            for buf in abl {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let channels = max(Int(buf.mNumberChannels), 1)
                let bufFrames = min(Int(buf.mDataByteSize) / (channels * 4),
                                    scratchCapacity)
                if totalChannels == 0 {
                    frames = bufFrames
                    for f in 0..<frames { scratch[f] = 0 }
                }
                frames = min(frames, bufFrames)
                for ch in 0..<channels {
                    for f in 0..<frames { scratch[f] += data[f * channels + ch] }
                }
                totalChannels += channels
            }
            guard frames > 0, totalChannels > 0 else { return }
            if totalChannels > 1 {
                let inv = 1.0 / Float(totalChannels)
                for f in 0..<frames { scratch[f] *= inv }
            }
            ring.write(scratch, stride: 1, frames: frames)
        }
        guard status == noErr, let pid else {
            throw MicError.ioProcFailed(status)
        }
        procID = pid
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
            throw MicError.startFailed(startStatus)
        }
        isRunning = true
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
        isRunning = false
    }

    func snapshot(seconds: Double) -> [Float] { ring.snapshot(seconds: seconds) }
    func level() -> Float { ring.levelRMS(seconds: 0.05) }

    enum MicError: LocalizedError {
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .ioProcFailed(let s): "Could not open the microphone (error \(s))"
            case .startFailed(let s): "Could not start the microphone (error \(s))"
            }
        }
    }
}
