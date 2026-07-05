import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Observation

// MARK: - Diagnostic log (~/Library/Logs/ParaEQ.log)

enum EngineLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ParaEQ.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ msg: String) {
        let line = "[\(formatter.string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 512_000 { return }
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Realtime context (no allocation on the IO thread)

/// Shared with the aggregate-device IOProc and the EQ's pull callback.
/// The IOProc stages tap input as planar audio, renders the EQ (which pulls
/// the staged audio through `eqInputCB`), and writes the result to the
/// device output buffers.
private final class IOCtx {
    let eqUnit: AudioUnit
    let maxFrames: Int
    let stageL: UnsafeMutablePointer<Float>
    let stageR: UnsafeMutablePointer<Float>
    var stagedFrames: Int = 0
    let eqABL: UnsafeMutablePointer<AudioBufferList>
    let preampPtr: UnsafeMutablePointer<Float>
    let volumePtr: UnsafeMutablePointer<Float>
    let peakLPtr: UnsafeMutablePointer<Float>
    let peakRPtr: UnsafeMutablePointer<Float>
    var callbackCount: UInt64 = 0

    init(eqUnit: AudioUnit, maxFrames: Int,
         preampPtr: UnsafeMutablePointer<Float>, volumePtr: UnsafeMutablePointer<Float>,
         peakLPtr: UnsafeMutablePointer<Float>, peakRPtr: UnsafeMutablePointer<Float>) {
        self.eqUnit = eqUnit
        self.maxFrames = maxFrames
        self.preampPtr = preampPtr
        self.volumePtr = volumePtr
        self.peakLPtr = peakLPtr
        self.peakRPtr = peakRPtr
        stageL = .allocate(capacity: maxFrames)
        stageL.initialize(repeating: 0, count: maxFrames)
        stageR = .allocate(capacity: maxFrames)
        stageR.initialize(repeating: 0, count: maxFrames)
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            abl[i] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                mData: .allocate(byteCount: maxFrames * 4, alignment: 4))
        }
        eqABL = abl.unsafeMutablePointer
    }

    deinit {
        stageL.deallocate()
        stageR.deallocate()
        let p = UnsafeMutableAudioBufferListPointer(eqABL)
        for i in 0..<Int(p.count) { p[i].mData?.deallocate() }
        free(eqABL)
    }
}

/// EQ input callback: feed the staged tap audio (with preamp) into the EQ.
private func eqInputCB(
    _ ref: UnsafeMutableRawPointer,
    _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UInt32, _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let c = Unmanaged<IOCtx>.fromOpaque(ref).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let n = min(Int(frames), c.stagedFrames)
    let preamp = c.preampPtr.pointee
    for (i, src) in [c.stageL, c.stageR].enumerated() where i < abl.count {
        guard let p = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        for j in 0..<n { p[j] = src[j] * preamp }
        if n < Int(frames) {
            p.advanced(by: n).initialize(repeating: 0, count: Int(frames) - n)
        }
    }
    return noErr
}

// MARK: - AudioEngine (Core Audio process-tap architecture)
//
// System audio → global process tap (.mutedWhenTapped, own PID excluded)
//   → private aggregate device (real output as main sub-device + the tap)
//   → single IOProc: tap input staged → NBandEQ (preamp in pull callback)
//   → volume + clip → device output buffers, all in one callback.
//
// No virtual driver, no ring buffer, and the system default output device is
// never touched — a crash can no longer silence the user's audio.

@Observable
final class AudioEngine {
    var bands: [EQBand] = makeDefaultBands()
    var isRunning = false
    /// nil = follow the system default output device
    var selectedOutput: AudioDevice?
    var volume: Float = 1.0
    var preamp: Float = 0            // dB, auto-calculated or manual
    var autoPreamp: Bool = true
    var errorMessage: String?
    var peakL: Float = 0
    var peakR: Float = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var eqUnit: AudioUnit?
    // macOS 26 requires a non-nil queue; nil silently registers no IOProc.
    private let ioQueue = DispatchQueue(label: "com.paraeq.io", qos: .userInteractive)

    private var volumePtr: UnsafeMutablePointer<Float>?
    private var preampLinearPtr: UnsafeMutablePointer<Float>?
    private var peakLPtr: UnsafeMutablePointer<Float>?
    private var peakRPtr: UnsafeMutablePointer<Float>?
    private var ioCtx: Unmanaged<IOCtx>?
    private var meterTimer: Timer?
    private var meterTicks = 0
    // Keeps App Nap from pausing our timers while the engine runs; the IO
    // callbacks live in coreaudiod-driven dispatch and survive napping, but
    // main-thread timers (meter, status log) do not.
    private var activityToken: NSObjectProtocol?
    private let listenerQueue = DispatchQueue(label: "com.paraeq.devicelistener")
    private var deviceChangeWork: DispatchWorkItem?   // accessed on listenerQueue only
    private var activeOutputUID: String?

    init() {
        loadState()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }

        installDeviceListeners()

        if UserDefaults.standard.bool(forKey: "paraeq.wasRunning") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isRunning else { return }
                EngineLog.log("Auto-resuming (was running at last quit)")
                self.start()
            }
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        do {
            guard let output = selectedOutput ?? AudioDeviceManager.defaultOutputDevice() else {
                throw EngineError.noOutputDevice
            }
            EngineLog.log("Starting: output \(output.name) (\(output.uid))"
                + (selectedOutput == nil ? " [system default]" : " [user-selected]"))

            volumePtr = .allocate(capacity: 1)
            volumePtr!.initialize(to: volume)
            peakLPtr = .allocate(capacity: 1)
            peakLPtr!.initialize(to: 0)
            peakRPtr = .allocate(capacity: 1)
            peakRPtr!.initialize(to: 0)
            preampLinearPtr = .allocate(capacity: 1)
            if autoPreamp { computeAutoPreamp() }
            preampLinearPtr!.initialize(to: powf(10.0, preamp / 20.0))

            let tapFormat = try createTap()
            try setupEQ(sampleRate: tapFormat.mSampleRate)
            try createAggregate(outputUID: output.uid)
            try startIO()
            activeOutputUID = output.uid

            applyAllBands()

            isRunning = true
            errorMessage = nil
            UserDefaults.standard.set(true, forKey: "paraeq.wasRunning")
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "ParaEQ audio processing")
            startMeterTimer()
            EngineLog.log(String(format: "Running: tap #%u agg #%u, %.0f Hz",
                                 tapID, aggregateID, tapFormat.mSampleRate))
        } catch {
            teardown()
            errorMessage = error.localizedDescription
            EngineLog.log("Start failed: \(error.localizedDescription)")
        }
    }

    /// `rememberOff: true` for the user's explicit Stop (disables auto-resume);
    /// internal restarts (device changes, quit) keep the resume flag.
    func stop(rememberOff: Bool = false) {
        meterTimer?.invalidate(); meterTimer = nil
        teardown()
        if isRunning { EngineLog.log("Stopped\(rememberOff ? " (by user)" : "")") }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        isRunning = false
        activeOutputUID = nil
        peakL = 0; peakR = 0
        if rememberOff { UserDefaults.standard.set(false, forKey: "paraeq.wasRunning") }
        saveState()
    }

    /// Restart with current device selection (used on device changes).
    func restart() {
        guard isRunning else { return }
        stop()
        start()
    }

    func outputSelectionChanged() {
        saveState()
        restart()
    }

    // MARK: - Tap + aggregate + IOProc

    private func createTap() throws -> AudioStreamBasicDescription {
        // Exclude our own process so our re-emitted output doesn't feed back.
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var selfProcess = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfProcess))

        let exclude: [AudioObjectID] = selfProcess == kAudioObjectUnknown ? [] : [selfProcess]
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "ParaEQ System Tap"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        tapUUID = desc.uuid

        let err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw EngineError.tapDenied(err) }

        var fmt = AudioStreamBasicDescription()
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt))
        return fmt
    }

    private var tapUUID: UUID?

    private func createAggregate(outputUID: String) throws {
        // The real output MUST be the main sub-device; a tap-only aggregate
        // silently produces zero samples.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ParaEQ Aggregate",
            kAudioAggregateDeviceUIDKey: "com.paraeq.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID!.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
    }

    private func startIO() throws {
        let ctx = IOCtx(eqUnit: eqUnit!, maxFrames: 4096,
                        preampPtr: preampLinearPtr!, volumePtr: volumePtr!,
                        peakLPtr: peakLPtr!, peakRPtr: peakRPtr!)
        let um = Unmanaged.passRetained(ctx)
        ioCtx = um
        try setEQRenderCallback()

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            inNow, inInputData, _, outOutputData, _ in
            let c = um.takeUnretainedValue()
            c.callbackCount &+= 1

            // 1. Stage tap input as planar L/R (handles interleaved or planar).
            var frames = 0
            var channel = 0
            let inABL = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buf in inABL {
                let n = max(Int(buf.mNumberChannels), 1)
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                frames = min(Int(buf.mDataByteSize) / (n * 4), c.maxFrames)
                for ch in 0..<n where channel < 2 {
                    let dst = channel == 0 ? c.stageL : c.stageR
                    for f in 0..<frames { dst[f] = data[f * n + ch] }
                    channel += 1
                }
            }
            // Mono tap → duplicate to both stage channels.
            if channel == 1 {
                for f in 0..<frames { c.stageR[f] = c.stageL[f] }
            }
            c.stagedFrames = frames
            guard frames > 0 else { return }

            // 2. Render the EQ (pulls staged audio via eqInputCB).
            let eqBufs = UnsafeMutableAudioBufferListPointer(c.eqABL)
            for i in 0..<2 { eqBufs[i].mDataByteSize = UInt32(frames * 4) }
            var flags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = AudioUnitRender(c.eqUnit, &flags, inNow, 0, UInt32(frames), c.eqABL)
            let srcL = status == noErr
                ? eqBufs[0].mData!.assumingMemoryBound(to: Float.self) : c.stageL
            let srcR = status == noErr
                ? eqBufs[1].mData!.assumingMemoryBound(to: Float.self) : c.stageR

            // 3. Volume + clip + peaks → device output buffers.
            let vol = c.volumePtr.pointee
            var peakL = c.peakLPtr.pointee
            var peakR = c.peakRPtr.pointee
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            var outChannel = 0
            for buf in outABL {
                let n = max(Int(buf.mNumberChannels), 1)
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let outFrames = Int(buf.mDataByteSize) / (n * 4)
                for ch in 0..<n {
                    let left = outChannel % 2 == 0
                    let src = left ? srcL : srcR
                    let count = min(outFrames, frames)
                    var peak = left ? peakL : peakR
                    for f in 0..<count {
                        var x = src[f] * vol
                        if x > 1.0 { x = 1.0 } else if x < -1.0 { x = -1.0 }
                        data[f * n + ch] = x
                        let a = x < 0 ? -x : x
                        if a > peak { peak = a }
                    }
                    for f in count..<outFrames { data[f * n + ch] = 0 }
                    if left { peakL = peak } else { peakR = peak }
                    outChannel += 1
                }
            }
            c.peakLPtr.pointee = peakL
            c.peakRPtr.pointee = peakR
        })
        try check(AudioDeviceStart(aggregateID, procID))
    }

    // MARK: - N-Band EQ (standalone AudioUnit, unchanged parameter mapping)

    private func setupEQ(sampleRate: Double) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.noAudioUnit
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au))
        guard let au else { throw EngineError.noAudioUnit }
        eqUnit = au

        var numBands = UInt32(bands.count)
        try check(AudioUnitSetProperty(au, 2200, // kAUNBandEQProperty_NumberOfBands
            kAudioUnitScope_Global, 0, &numBands, 4))

        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var maxFrames: UInt32 = 4096
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxFrames, 4))
    }

    private func setEQRenderCallback() throws {
        var cb = AURenderCallbackStruct(inputProc: eqInputCB,
                                        inputProcRefCon: ioCtx!.toOpaque())
        try check(AudioUnitSetProperty(eqUnit!, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(eqUnit!))
    }

    // MARK: - Device-change handling
    //
    // Listeners live on a dedicated queue that the engine NEVER blocks.
    // Teardown calls (AudioDeviceDestroyIOProcID etc.) message coreaudiod
    // synchronously, and coreaudiod may concurrently be delivering a property
    // notification to us — if the listener queue is the thread doing the
    // teardown, the two wait on each other forever (observed deadlock).

    private func installDeviceListeners() {
        let listener: (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
            [weak self] _, _ in
            self?.scheduleDeviceChangeCheck()
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, listener)
        }
    }

    /// Runs on `listenerQueue`. Debounces the burst of property changes a
    /// device switch produces, then evaluates on the main thread.
    private func scheduleDeviceChangeCheck() {
        deviceChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.evaluateDeviceChange() }
        }
        deviceChangeWork = work
        listenerQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func evaluateDeviceChange() {
        guard isRunning else { return }
        if let selected = selectedOutput,
           !AudioDeviceManager.outputDevices().contains(where: { $0.uid == selected.uid }) {
            EngineLog.log("Selected output '\(selected.name)' disappeared; following system default")
            selectedOutput = nil
        }
        // Only restart when the effective route actually changed — our own
        // aggregate create/destroy also fires device-list notifications.
        let target = (selectedOutput ?? AudioDeviceManager.defaultOutputDevice())?.uid
        guard target != activeOutputUID else { return }
        EngineLog.log("Output route changed (\(activeOutputUID ?? "none") → \(target ?? "none")); restarting")
        restart()
    }

    // MARK: - Band updates

    func applyBand(at index: Int) {
        guard let eq = eqUnit, isRunning else { return }
        let b = bands[index]
        let i = AudioUnitParameterID(index)
        AudioUnitSetParameter(eq, 2000 + i, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(b.filterType.avType.rawValue), 0)
        AudioUnitSetParameter(eq, 3000 + i, kAudioUnitScope_Global, 0, b.frequency, 0)
        AudioUnitSetParameter(eq, 4000 + i, kAudioUnitScope_Global, 0,
            b.enabled ? b.gain : 0, 0)
        AudioUnitSetParameter(eq, 5000 + i, kAudioUnitScope_Global, 0, b.bandwidth, 0)
        AudioUnitSetParameter(eq, 1000 + i, kAudioUnitScope_Global, 0,
            b.enabled ? 0 : 1, 0)
        if autoPreamp { computeAutoPreamp() }
    }

    func applyAllBands() {
        for i in bands.indices { applyBand(at: i) }
        if autoPreamp { computeAutoPreamp() }
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.bands.count == bands.count else { return }
        bands = preset.bands
        if let p = preset.preamp {
            autoPreamp = false
            setPreamp(p)
        }
        applyAllBands()
    }

    func setVolume(_ v: Float) {
        volume = v
        volumePtr?.pointee = v
    }

    func setPreamp(_ dB: Float) {
        preamp = dB
        preampLinearPtr?.pointee = powf(10.0, dB / 20.0)
    }

    /// Compute preamp reduction so EQ peak boost stays at 0 dB.
    func computeAutoPreamp() {
        let peakDB = FrequencyResponse.peakGainDB(for: bands)
        let newPreamp = peakDB > 0 ? -peakDB : Float(0)
        preamp = newPreamp
        preampLinearPtr?.pointee = powf(10.0, newPreamp / 20.0)
    }

    // MARK: - Persistence

    func saveState() {
        if let data = try? JSONEncoder().encode(bands) {
            UserDefaults.standard.set(data, forKey: "paraeq.bands")
        }
        UserDefaults.standard.set(volume, forKey: "paraeq.volume")
        UserDefaults.standard.set(autoPreamp, forKey: "paraeq.autoPreamp")
        if !autoPreamp { UserDefaults.standard.set(preamp, forKey: "paraeq.preamp") }
        UserDefaults.standard.set(selectedOutput?.uid ?? "", forKey: "paraeq.outputUID")
    }

    func loadState() {
        if let data = UserDefaults.standard.data(forKey: "paraeq.bands"),
           let saved = try? JSONDecoder().decode([EQBand].self, from: data),
           saved.count == bands.count { bands = saved }
        let v = UserDefaults.standard.float(forKey: "paraeq.volume")
        if v > 0 { volume = v }
        if UserDefaults.standard.object(forKey: "paraeq.autoPreamp") != nil {
            autoPreamp = UserDefaults.standard.bool(forKey: "paraeq.autoPreamp")
        }
        if !autoPreamp {
            preamp = UserDefaults.standard.float(forKey: "paraeq.preamp")
        }
        if let uid = UserDefaults.standard.string(forKey: "paraeq.outputUID"), !uid.isEmpty {
            selectedOutput = AudioDeviceManager.outputDevices().first { $0.uid == uid }
        }
    }

    // MARK: - Peak meter polling

    private func startMeterTimer() {
        meterTicks = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let lp = self.peakLPtr, let rp = self.peakRPtr else { return }
            let rawL = lp.pointee; lp.pointee = 0
            let rawR = rp.pointee; rp.pointee = 0
            self.peakL = max(rawL, self.peakL * 0.85)
            self.peakR = max(rawR, self.peakR * 0.85)
            self.meterTicks += 1
            if self.meterTicks == 1 { EngineLog.log("meter timer alive") }
            if self.meterTicks % 300 == 0, let ctx = self.ioCtx?.takeUnretainedValue() {
                EngineLog.log(String(format: "status: callbacks=%llu peakL=%.3f peakR=%.3f",
                                     ctx.callbackCount, self.peakL, self.peakR))
            }
        }
    }

    // MARK: - Teardown

    private func teardown() {
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
        if let u = eqUnit {
            AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
            eqUnit = nil
        }
        ioCtx?.release(); ioCtx = nil
        if let p = volumePtr { p.deallocate(); volumePtr = nil }
        if let p = preampLinearPtr { p.deallocate(); preampLinearPtr = nil }
        if let p = peakLPtr { p.deallocate(); peakLPtr = nil }
        if let p = peakRPtr { p.deallocate(); peakRPtr = nil }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw EngineError.osStatus(status) }
    }

    enum EngineError: LocalizedError {
        case noAudioUnit
        case noOutputDevice
        case tapDenied(OSStatus)
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noAudioUnit: "Could not access audio unit"
            case .noOutputDevice: "No output device available"
            case .tapDenied(let s):
                "Could not tap system audio (error \(s)). Check System Settings → "
                + "Privacy & Security → Screen & System Audio Recording."
            case .osStatus(let s): "Audio error \(s)"
            }
        }
    }
}
