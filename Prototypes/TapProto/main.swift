// TapProto — prototype validating the Core Audio process-tap architecture:
//   global tap (.mutedWhenTapped, own PID excluded) → aggregate device with the
//   real default output → single IOProc doing passthrough with a periodic gain
//   dip so intercept-and-reroute is audibly verifiable.
// Logs to ~/Library/Logs/TapProto.log. Runs ~45 s, then cleans up and exits.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/TapProto.log")

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ msg: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'\(String(bytes: bytes, encoding: .ascii)!)'"
    }
    return "\(status)"
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func check(_ err: OSStatus, _ what: String) throws {
    guard err == noErr else { throw Err("\(what) failed: \(fourCC(err))") }
}

// MARK: - Prototype

@available(macOS 14.2, *)
final class TapProto {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    // macOS 26 requires a non-nil queue here; nil silently registers nothing.
    private let ioQueue = DispatchQueue(label: "com.paraeq.tapproto.io", qos: .userInteractive)

    // Written by the main-thread timer, read on the IO queue. Plain vars are
    // fine for a prototype (single word, torn reads harmless here).
    private var gain: Float = 1.0
    private var peak: Float = 0
    private var callbackCount: UInt64 = 0
    private var tick = 0

    func run() throws {
        // 1. Own process object, so we can exclude ourselves from the tap
        //    (otherwise our re-emitted output feeds back into the tap).
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var selfProcess = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfProcess),
            "TranslatePIDToProcessObject")
        log("Own CoreAudio process object: #\(selfProcess)")

        // 2. Global system tap, muted-while-tapped, excluding our own process.
        //    NOTE: never touch .isExclusive after this init — flipping it
        //    inverts include/exclude semantics and yields silence.
        let exclude: [AudioObjectID] = selfProcess == kAudioObjectUnknown ? [] : [selfProcess]
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "ParaEQ TapProto"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        let createErr = AudioHardwareCreateProcessTap(desc, &tapID)
        guard createErr == noErr else {
            throw Err("AudioHardwareCreateProcessTap failed: \(fourCC(createErr)) — "
                + "if no permission prompt appeared, this is the TCC/signing issue "
                + "(System Settings → Privacy & Security → Screen & System Audio Recording)")
        }
        log("Process tap created: #\(tapID)")

        // 3. Tap stream format.
        var fmt = AudioStreamBasicDescription()
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt), "read tap format")
        log(String(format: "Tap format: %.0f Hz, %d ch, flags 0x%x, %d bytes/frame",
                   fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mFormatFlags, fmt.mBytesPerFrame))

        // 4. Default output device UID (the aggregate's main sub-device MUST be
        //    a real output device; a tap-only aggregate yields silent zeros).
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &outputDevice),
            "read default output device")
        var uidCF: CFString = "" as CFString
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(outputDevice, &addr, 0, nil, &size, &uidCF),
                  "read output device UID")
        let outputUID = uidCF as String
        log("Default output device: #\(outputDevice) UID=\(outputUID)")

        // 5. Private aggregate: real output as main sub-device + the tap.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ParaEQ TapProto Aggregate",
            kAudioAggregateDeviceUIDKey: "com.paraeq.tapproto.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")
        log("Aggregate device created: #\(aggregateID)")

        // 6. Single IOProc: tap audio arrives as input, we write the real
        //    output buffers in the same callback. Passthrough × gain.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [unowned self] _, inInputData, _, outOutputData, _ in
            self.process(input: inInputData, output: outOutputData)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        log("IOProc started — passthrough running. Gain dips to 0.25 every other 3 s tick.")

        // Status timer + gain toggle on the main run loop.
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [unowned self] timer in
            self.tick += 1
            let p = self.peak
            self.peak = 0
            log(String(format: "tick %d: callbacks=%llu peak=%.4f gain=%.2f",
                       self.tick, self.callbackCount, p, self.gain))
            self.gain = (self.tick % 2 == 1) ? 0.25 : 1.0
            if self.tick >= 15 {
                timer.invalidate()
                self.teardown()
                log("Done. TapProto exiting.")
                exit(0)
            }
        }
    }

    private func process(input: UnsafePointer<AudioBufferList>,
                         output: UnsafeMutablePointer<AudioBufferList>) {
        callbackCount &+= 1
        let g = gain
        var maxPeak = peak

        // Flatten both ABLs into (basePointer, stride) per channel so
        // interleaved and planar layouts are handled uniformly.
        var inChans: [(UnsafeMutablePointer<Float>, Int)] = []
        var frames = 0
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for buf in inABL {
            let n = max(Int(buf.mNumberChannels), 1)
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            frames = Int(buf.mDataByteSize) / (n * MemoryLayout<Float>.size)
            for c in 0..<n { inChans.append((data + c, n)) }
        }

        let outABL = UnsafeMutableAudioBufferListPointer(output)
        var outIndex = 0
        for buf in outABL {
            let n = max(Int(buf.mNumberChannels), 1)
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = Int(buf.mDataByteSize) / (n * MemoryLayout<Float>.size)
            for c in 0..<n {
                let out = data + c
                if inChans.isEmpty {
                    for f in 0..<outFrames { out[f * n] = 0 }
                } else {
                    let (src, stride) = inChans[min(outIndex, inChans.count - 1)]
                    let count = min(outFrames, frames)
                    for f in 0..<count {
                        let s = src[f * stride] * g
                        out[f * n] = s
                        let a = abs(s)
                        if a > maxPeak { maxPeak = a }
                    }
                    for f in count..<outFrames { out[f * n] = 0 }
                }
                outIndex += 1
            }
        }
        peak = maxPeak
    }

    func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        log("Teardown complete (tap + aggregate destroyed).")
    }
}

// MARK: - Entry point

@available(macOS 14.2, *)
func runMain() {
    let proto = TapProto()

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    sigintSource.setEventHandler {
        proto.teardown()
        log("Interrupted. TapProto exiting.")
        exit(0)
    }
    sigintSource.resume()

    do {
        try proto.run()
    } catch {
        log("FATAL: \(error)")
        exit(1)
    }

    RunLoop.main.run()
}

try? FileManager.default.removeItem(at: logURL)
log("TapProto starting, pid \(ProcessInfo.processInfo.processIdentifier)")

if #available(macOS 14.2, *) {
    runMain()
} else {
    log("FATAL: macOS 14.2+ required for process taps")
    exit(1)
}
