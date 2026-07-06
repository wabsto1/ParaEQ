import AppKit
import AudioToolbox
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

/// Shared with the aggregate-device IOProc. The IOProc stages tap input as
/// planar audio (applying preamp), runs the biquad chain, and writes the
/// result to the device output buffers.
private final class IOCtx {
    let eq: BiquadEQ
    let limiter: Limiter
    let crossfeed: Crossfeed?
    let convolver: FIRConvolver?
    let spectrum: SpectrumTap?
    let midSide: Bool
    let maxFrames: Int
    let stageL: UnsafeMutablePointer<Float>
    let stageR: UnsafeMutablePointer<Float>
    let outL: UnsafeMutablePointer<Float>
    let outR: UnsafeMutablePointer<Float>
    let preampPtr: UnsafeMutablePointer<Float>
    let volumePtr: UnsafeMutablePointer<Float>
    let balancePtr: UnsafeMutablePointer<Float>
    let bypassPtr: UnsafeMutablePointer<Float>
    let peakLPtr: UnsafeMutablePointer<Float>
    let peakRPtr: UnsafeMutablePointer<Float>
    var callbackCount: UInt64 = 0

    init(eq: BiquadEQ, limiter: Limiter, crossfeed: Crossfeed?,
         convolver: FIRConvolver?, spectrum: SpectrumTap?, midSide: Bool,
         maxFrames: Int,
         preampPtr: UnsafeMutablePointer<Float>, volumePtr: UnsafeMutablePointer<Float>,
         balancePtr: UnsafeMutablePointer<Float>, bypassPtr: UnsafeMutablePointer<Float>,
         peakLPtr: UnsafeMutablePointer<Float>, peakRPtr: UnsafeMutablePointer<Float>) {
        self.eq = eq
        self.limiter = limiter
        self.crossfeed = crossfeed
        self.convolver = convolver
        self.spectrum = spectrum
        self.midSide = midSide
        self.maxFrames = maxFrames
        self.preampPtr = preampPtr
        self.volumePtr = volumePtr
        self.balancePtr = balancePtr
        self.bypassPtr = bypassPtr
        self.peakLPtr = peakLPtr
        self.peakRPtr = peakRPtr
        stageL = .allocate(capacity: maxFrames)
        stageL.initialize(repeating: 0, count: maxFrames)
        stageR = .allocate(capacity: maxFrames)
        stageR.initialize(repeating: 0, count: maxFrames)
        outL = .allocate(capacity: maxFrames)
        outL.initialize(repeating: 0, count: maxFrames)
        outR = .allocate(capacity: maxFrames)
        outR.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        stageL.deallocate()
        stageR.deallocate()
        outL.deallocate()
        outR.deallocate()
    }
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
    /// Second band set: Right channel (stereo mode) or Side (mid-side mode).
    var bandsB: [EQBand] = makeDefaultBands()
    var channelMode: ChannelMode = .linked
    /// Which set the UI is editing when channelMode != .linked.
    var editingB = false
    var balance: Float = 0          // -1 full left … +1 full right
    var crossfeedMode: CrossfeedMode = .off
    /// GraphicEQ curve (minimum-phase FIR stage); nil = off.
    var graphicEQNodes: [GraphicEQNode]?
    /// Loaded impulse response(s) for convolution; nil = off.
    var impulseResponse: [[Float]]?
    var impulseResponseName: String?
    var isRunning = false
    /// A/B comparison: true = tonal stages skipped (volume/limiter stay).
    var bypassed = false
    /// Resolves a preset ID to a preset (wired to the PresetManager by the UI).
    var presetLookup: ((String) -> EQPreset?)?
    private var lastAutoProfileID: String?

    /// The band set currently shown/edited in the UI.
    var activeBands: [EQBand] {
        get { editingB && channelMode != .linked ? bandsB : bands }
        set {
            if editingB && channelMode != .linked { bandsB = newValue }
            else { bands = newValue }
        }
    }
    /// nil = follow the system default output device
    var selectedOutput: AudioDevice?
    var volume: Float = 1.0
    var preamp: Float = 0            // dB, auto-calculated or manual
    var autoPreamp: Bool = true
    var errorMessage: String?
    var peakL: Float = 0
    var peakR: Float = 0
    /// Live spectrum display (dB per log-spaced bin), fed by the meter timer.
    var showSpectrum = true
    var spectrumPre: [Float] = []
    var spectrumPost: [Float] = []
    var canUndo = false
    var canRedo = false
    @ObservationIgnored private var spectrumTap: SpectrumTap?
    @ObservationIgnored private let spectrumFreqs =
        FrequencyResponse.logFrequencies(count: 120)
    @ObservationIgnored private var history: EditHistory<EQEditState>!

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var biquad: BiquadEQ?
    // macOS 26 requires a non-nil queue; nil silently registers no IOProc.
    private let ioQueue = DispatchQueue(label: "com.paraeq.io", qos: .userInteractive)

    private var volumePtr: UnsafeMutablePointer<Float>?
    private var balancePtr: UnsafeMutablePointer<Float>?
    private var bypassPtr: UnsafeMutablePointer<Float>?
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
        history = EditHistory(initial: currentEditState)
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

            // Device auto-profile: apply this output's assigned preset once.
            if let pid = deviceProfile(forUID: output.uid), pid != lastAutoProfileID,
               let preset = presetLookup?(pid) {
                lastAutoProfileID = pid
                bands = preset.bands
                bandsB = preset.bands
                if let p = preset.preamp { autoPreamp = false; preamp = p }
                EngineLog.log("Applied device profile preset '\(preset.name)'")
            }

            volumePtr = .allocate(capacity: 1)
            volumePtr!.initialize(to: volume)
            balancePtr = .allocate(capacity: 1)
            balancePtr!.initialize(to: balance)
            bypassPtr = .allocate(capacity: 1)
            bypassPtr!.initialize(to: bypassed ? 1 : 0)
            peakLPtr = .allocate(capacity: 1)
            peakLPtr!.initialize(to: 0)
            peakRPtr = .allocate(capacity: 1)
            peakRPtr!.initialize(to: 0)
            preampLinearPtr = .allocate(capacity: 1)
            if autoPreamp { computeAutoPreamp() }
            preampLinearPtr!.initialize(to: powf(10.0, preamp / 20.0))

            let tapFormat = try createTap()
            FrequencyResponse.sampleRate = tapFormat.mSampleRate
            guard let eq = BiquadEQ(
                bandsA: bands,
                bandsB: channelMode == .linked ? nil : bandsB,
                sampleRate: tapFormat.mSampleRate) else {
                throw EngineError.noAudioUnit
            }
            biquad = eq
            try createAggregate(outputUID: output.uid)
            try startIO()
            activeOutputUID = output.uid

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
        spectrumPre = []; spectrumPost = []
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
        // FIR stage: explicit IR wins; otherwise GraphicEQ curve if set.
        var convolver: FIRConvolver?
        if let irs = impulseResponse {
            convolver = FIRConvolver(impulseResponses: irs)
        } else if let nodes = graphicEQNodes, !nodes.isEmpty {
            let fir = MinPhaseFIR.design(nodes: nodes, sampleRate: biquad!.sampleRate)
            convolver = FIRConvolver(impulseResponses: [fir])
        }
        if convolver != nil {
            EngineLog.log("FIR stage active (\(impulseResponseName ?? "GraphicEQ"))")
        }
        let spectrum = SpectrumTap(sampleRate: biquad!.sampleRate)
        spectrumTap = spectrum
        let ctx = IOCtx(eq: biquad!,
                        limiter: Limiter(sampleRate: biquad!.sampleRate),
                        crossfeed: crossfeedMode == .off ? nil
                            : Crossfeed(mode: crossfeedMode, sampleRate: biquad!.sampleRate),
                        convolver: convolver,
                        spectrum: spectrum,
                        midSide: channelMode == .midSide,
                        maxFrames: 4096,
                        preampPtr: preampLinearPtr!, volumePtr: volumePtr!,
                        balancePtr: balancePtr!, bypassPtr: bypassPtr!,
                        peakLPtr: peakLPtr!, peakRPtr: peakRPtr!)
        let um = Unmanaged.passRetained(ctx)
        ioCtx = um

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            _, inInputData, _, outOutputData, _ in
            let c = um.takeUnretainedValue()
            c.callbackCount &+= 1

            // 1. Stage tap input as planar L/R
            //    (handles interleaved or planar input layouts).
            var frames = 0
            var channel = 0
            let bypassed = c.bypassPtr.pointee > 0.5
            let preamp = bypassed ? 1.0 : c.preampPtr.pointee
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
            guard frames > 0 else { return }
            // Pre-EQ spectrum sees the raw source, before preamp.
            c.spectrum?.writePre(l: c.stageL, r: c.stageR, frames: frames)
            if preamp != 1.0 {
                for f in 0..<frames {
                    c.stageL[f] *= preamp
                    c.stageR[f] *= preamp
                }
            }

            // 2. [M/S encode] → biquad chain → [M/S decode] → FIR → crossfeed
            //    → balance + volume → lookahead limiter.
            //    Bypass (A/B) skips all tonal stages but keeps volume/limiter.
            if bypassed {
                for f in 0..<frames {
                    c.outL[f] = c.stageL[f]
                    c.outR[f] = c.stageR[f]
                }
            } else {
                if c.midSide {
                    for f in 0..<frames {
                        let m = (c.stageL[f] + c.stageR[f]) * 0.5
                        let s = (c.stageL[f] - c.stageR[f]) * 0.5
                        c.stageL[f] = m
                        c.stageR[f] = s
                    }
                }
                c.eq.process(inL: c.stageL, inR: c.stageR,
                             outL: c.outL, outR: c.outR, frames: frames)
                if c.midSide {
                    for f in 0..<frames {
                        let m = c.outL[f]
                        let s = c.outR[f]
                        c.outL[f] = m + s
                        c.outR[f] = m - s
                    }
                }
                c.convolver?.process(l: c.outL, r: c.outR, frames: frames)
                c.crossfeed?.process(l: c.outL, r: c.outR, frames: frames)
            }
            let vol = c.volumePtr.pointee
            let bal = c.balancePtr.pointee
            let gL = vol * (bal > 0 ? 1 - bal : 1)
            let gR = vol * (bal < 0 ? 1 + bal : 1)
            if gL != 1.0 || gR != 1.0 {
                for f in 0..<frames {
                    c.outL[f] *= gL
                    c.outR[f] *= gR
                }
            }
            c.limiter.process(l: c.outL, r: c.outR, frames: frames)
            c.spectrum?.writePost(l: c.outL, r: c.outR, frames: frames)
            let srcL = c.outL
            let srcR = c.outR

            // 3. Peaks + copy to device output buffers.
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
                        let x = src[f]
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

    // MARK: - Undo / redo (bands + preamp, slider drags coalesced)

    struct EQEditState: Equatable {
        var bands: [EQBand]
        var bandsB: [EQBand]
        var preamp: Float
        var autoPreamp: Bool
    }

    private var currentEditState: EQEditState {
        EQEditState(bands: bands, bandsB: bandsB,
                    preamp: preamp, autoPreamp: autoPreamp)
    }

    private func recordEditState() {
        history.recordEdit(currentEditState)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    func undoEdit() {
        guard let state = history.undo(current: currentEditState) else { return }
        applyEditState(state)
    }

    func redoEdit() {
        guard let state = history.redo(current: currentEditState) else { return }
        applyEditState(state)
    }

    private func applyEditState(_ state: EQEditState) {
        let countChanged = state.bands.count != bands.count
            || state.bandsB.count != bandsB.count
        bands = state.bands
        bandsB = state.bandsB
        autoPreamp = state.autoPreamp
        preamp = state.preamp
        preampLinearPtr?.pointee = powf(10.0, state.preamp / 20.0)
        bandStructureChanged(countChanged: countChanged)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - Band updates

    func applyBand(at index: Int) {
        applyAllBands()
    }

    func applyAllBands() {
        let setB = channelMode == .linked ? nil : bandsB
        if let biquad, !biquad.update(bandsA: bands, bandsB: setB), isRunning {
            // Section count changed (crossover type toggled) — rebuild chain.
            restart()
            recordEditState()
            return
        }
        if autoPreamp { computeAutoPreamp() }
        recordEditState()
        scheduleSave()
    }

    func setChannelMode(_ mode: ChannelMode) {
        guard mode != channelMode else { return }
        if channelMode == .linked {
            bandsB = bands   // start the second set from the current curve
        }
        channelMode = mode
        editingB = false
        if isRunning {
            restart()
            recordEditState()
        } else {
            applyAllBands()
        }
        scheduleSave()
    }

    func setCrossfeedMode(_ mode: CrossfeedMode) {
        guard mode != crossfeedMode else { return }
        crossfeedMode = mode
        if isRunning { restart() }
        scheduleSave()
    }

    func setBalance(_ value: Float) {
        balance = value
        balancePtr?.pointee = value
        scheduleSave()
    }

    func setBypassed(_ on: Bool) {
        bypassed = on
        bypassPtr?.pointee = on ? 1 : 0
    }

    // MARK: - Device auto-profiles (preset per output device)

    var currentOutputUID: String? {
        selectedOutput?.uid ?? AudioDeviceManager.defaultOutputDevice()?.uid
    }

    func deviceProfile(forUID uid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "paraeq.deviceProfiles")
            as? [String: String])?[uid]
    }

    /// Assign (or clear, with nil) a preset to an output device.
    func assignDeviceProfile(presetID: String?, forUID uid: String) {
        var map = (UserDefaults.standard.dictionary(forKey: "paraeq.deviceProfiles")
            as? [String: String]) ?? [:]
        map[uid] = presetID
        UserDefaults.standard.set(map, forKey: "paraeq.deviceProfiles")
        EngineLog.log("Device profile for \(uid): \(presetID ?? "cleared")")
    }

    /// Export the active band set + preamp as EqualizerAPO ParametricEQ text.
    func exportEqualizerAPOText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preamp)]
        var n = 1
        for b in activeBands where b.enabled {
            let code: String? = switch b.filterType {
            case .parametric: "PK"
            case .lowShelf: "LSC"
            case .highShelf: "HSC"
            case .lowPass: "LPQ"
            case .highPass: "HPQ"
            case .bandPass: "BP"
            case .bandStop: "NO"
            default: nil   // crossover cascades have no single-line APO form
            }
            guard let code else { continue }
            lines.append(String(
                format: "Filter %d: ON %@ Fc %.1f Hz Gain %.1f dB Q %.2f",
                n, code, b.frequency, b.gain, b.q))
            n += 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func setGraphicEQ(_ nodes: [GraphicEQNode]?) {
        graphicEQNodes = nodes
        if isRunning { restart() }
        scheduleSave()
    }

    /// Load an impulse response audio file (resampled to the engine rate).
    func loadImpulseResponse(url: URL) {
        do {
            let rate = biquad?.sampleRate ?? FrequencyResponse.sampleRate
            let irs = try IRLoader.load(url: url, targetSampleRate: rate)
            impulseResponse = irs
            impulseResponseName = url.lastPathComponent
            EngineLog.log("Loaded IR '\(url.lastPathComponent)' (\(irs[0].count) taps)")
            if isRunning { restart() }
        } catch {
            errorMessage = "IR load failed: \(error.localizedDescription)"
            EngineLog.log("IR load failed: \(error)")
        }
    }

    func clearImpulseResponse() {
        impulseResponse = nil
        impulseResponseName = nil
        if isRunning { restart() }
    }

    /// Debounced persistence so a crash never loses more than ~1 s of edits.
    private var saveWork: DispatchWorkItem?
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func applyPreset(_ preset: EQPreset) {
        guard !preset.bands.isEmpty else { return }
        let countChanged = preset.bands.count != bands.count
            || (channelMode != .linked && preset.bands.count != bandsB.count)
        bands = preset.bands
        bandsB = preset.bands
        if let p = preset.preamp {
            autoPreamp = false
            setPreamp(p)
        }
        bandStructureChanged(countChanged: countChanged)
    }

    func setLayout(_ layout: BandLayout) {
        let countChanged = layout.frequencies.count != bands.count
            || layout.frequencies.count != bandsB.count
        bands = makeDefaultBands(layout)
        bandsB = makeDefaultBands(layout)
        bandStructureChanged(countChanged: countChanged)
    }

    /// Adds a band centered in the largest frequency gap, Q matched to it.
    func addBand() {
        activeBands.append(makeSuggestedBand(existing: activeBands))
        bandStructureChanged(countChanged: true)
    }

    func removeBand(at index: Int) {
        guard activeBands.count > 1, activeBands.indices.contains(index) else { return }
        activeBands.remove(at: index)
        bandStructureChanged(countChanged: true)
    }

    /// The biquad chain's section count is fixed at start; a band-count
    /// change while running needs an engine rebuild (~50 ms).
    private func bandStructureChanged(countChanged: Bool) {
        if countChanged, isRunning {
            restart()
            recordEditState()
        } else {
            applyAllBands()
        }
        saveState()
    }

    func setVolume(_ v: Float) {
        volume = v
        volumePtr?.pointee = v
        scheduleSave()
    }

    func setPreamp(_ dB: Float) {
        preamp = dB
        preampLinearPtr?.pointee = powf(10.0, dB / 20.0)
        recordEditState()
        scheduleSave()
    }

    func setAutoPreamp(_ on: Bool) {
        autoPreamp = on
        if on { computeAutoPreamp() }
        recordEditState()
        scheduleSave()
    }

    func setShowSpectrum(_ on: Bool) {
        showSpectrum = on
        if !on {
            spectrumPre = []
            spectrumPost = []
        }
        scheduleSave()
    }

    /// Compute preamp reduction so EQ peak boost stays at 0 dB
    /// (worst case across both channel band sets).
    func computeAutoPreamp() {
        var peakDB = FrequencyResponse.peakGainDB(for: bands)
        if channelMode != .linked {
            peakDB = max(peakDB, FrequencyResponse.peakGainDB(for: bandsB))
        }
        let newPreamp = peakDB > 0 ? -peakDB : Float(0)
        preamp = newPreamp
        preampLinearPtr?.pointee = powf(10.0, newPreamp / 20.0)
    }

    // MARK: - Persistence

    func saveState() {
        if let data = try? JSONEncoder().encode(bands) {
            UserDefaults.standard.set(data, forKey: "paraeq.bands")
        }
        if let data = try? JSONEncoder().encode(bandsB) {
            UserDefaults.standard.set(data, forKey: "paraeq.bandsB")
        }
        if let nodes = graphicEQNodes, let data = try? JSONEncoder().encode(nodes) {
            UserDefaults.standard.set(data, forKey: "paraeq.graphicEQ")
        } else {
            UserDefaults.standard.removeObject(forKey: "paraeq.graphicEQ")
        }
        UserDefaults.standard.set(channelMode.rawValue, forKey: "paraeq.channelMode")
        UserDefaults.standard.set(crossfeedMode.rawValue, forKey: "paraeq.crossfeed")
        UserDefaults.standard.set(balance, forKey: "paraeq.balance")
        UserDefaults.standard.set(volume, forKey: "paraeq.volume")
        UserDefaults.standard.set(autoPreamp, forKey: "paraeq.autoPreamp")
        UserDefaults.standard.set(showSpectrum, forKey: "paraeq.showSpectrum")
        if !autoPreamp { UserDefaults.standard.set(preamp, forKey: "paraeq.preamp") }
        UserDefaults.standard.set(selectedOutput?.uid ?? "", forKey: "paraeq.outputUID")
    }

    func loadState() {
        if let data = UserDefaults.standard.data(forKey: "paraeq.bands"),
           let saved = try? JSONDecoder().decode([EQBand].self, from: data),
           !saved.isEmpty { bands = saved }
        if let data = UserDefaults.standard.data(forKey: "paraeq.bandsB"),
           let saved = try? JSONDecoder().decode([EQBand].self, from: data),
           !saved.isEmpty { bandsB = saved } else { bandsB = bands }
        if let data = UserDefaults.standard.data(forKey: "paraeq.graphicEQ"),
           let nodes = try? JSONDecoder().decode([GraphicEQNode].self, from: data),
           !nodes.isEmpty { graphicEQNodes = nodes }
        if let raw = UserDefaults.standard.string(forKey: "paraeq.channelMode"),
           let mode = ChannelMode(rawValue: raw) { channelMode = mode }
        if let raw = UserDefaults.standard.string(forKey: "paraeq.crossfeed"),
           let mode = CrossfeedMode(rawValue: raw) { crossfeedMode = mode }
        balance = UserDefaults.standard.float(forKey: "paraeq.balance")
        let v = UserDefaults.standard.float(forKey: "paraeq.volume")
        if v > 0 { volume = v }
        if UserDefaults.standard.object(forKey: "paraeq.autoPreamp") != nil {
            autoPreamp = UserDefaults.standard.bool(forKey: "paraeq.autoPreamp")
        }
        if UserDefaults.standard.object(forKey: "paraeq.showSpectrum") != nil {
            showSpectrum = UserDefaults.standard.bool(forKey: "paraeq.showSpectrum")
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
            if self.showSpectrum, let tap = self.spectrumTap {
                let (pre, post) = tap.analyze(frequencies: self.spectrumFreqs)
                self.spectrumPre = pre
                self.spectrumPost = post
            }
            self.meterTicks += 1
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
        ioCtx?.release(); ioCtx = nil
        spectrumTap = nil
        biquad = nil
        if let p = volumePtr { p.deallocate(); volumePtr = nil }
        if let p = balancePtr { p.deallocate(); balancePtr = nil }
        if let p = bypassPtr { p.deallocate(); bypassPtr = nil }
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
            case .noAudioUnit: "Could not create EQ processor"
            case .noOutputDevice: "No output device available"
            case .tapDenied(let s):
                "Could not tap system audio (error \(s)). Check System Settings → "
                + "Privacy & Security → Screen & System Audio Recording."
            case .osStatus(let s): "Audio error \(s)"
            }
        }
    }
}
