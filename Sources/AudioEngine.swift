import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Observation

// MARK: - Ring buffer (single-producer / single-consumer)

private final class FloatRingBuffer: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private var wp = 0
    private var rp = 0

    init(capacity: Int) {
        cap = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    func write(_ src: UnsafePointer<Float>, count: Int) {
        var w = wp
        for i in 0..<count {
            buf[w] = src[i]; w += 1; if w == cap { w = 0 }
        }
        wp = w
    }

    func read(_ dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = wp; var r = rp; var n = 0
        while n < count, r != w {
            dst[n] = buf[r]; r += 1; if r == cap { r = 0 }; n += 1
        }
        rp = r
        return n
    }
}

// MARK: - Callback contexts (prevent any allocation on audio thread)

/// Passed to the input AUHAL callback (BlackHole → ring buffer)
private final class InputCBCtx {
    let au: AudioUnit
    let ringL: FloatRingBuffer, ringR: FloatRingBuffer
    let renderBuf: UnsafeMutablePointer<AudioBufferList>

    init(au: AudioUnit, ringL: FloatRingBuffer, ringR: FloatRingBuffer, maxFrames: UInt32) {
        self.au = au; self.ringL = ringL; self.ringR = ringR
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            abl[i] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: maxFrames * 4,
                mData: .allocate(byteCount: Int(maxFrames) * 4, alignment: 4))
        }
        renderBuf = abl.unsafeMutablePointer
    }
    deinit {
        let p = UnsafeMutableAudioBufferListPointer(renderBuf)
        for i in 0..<Int(p.count) { p[i].mData?.deallocate() }
        free(renderBuf)
    }
}

/// Passed to the EQ input render callback (ring buffer → EQ)
private final class EQInputCtx {
    let ringL: FloatRingBuffer, ringR: FloatRingBuffer
    init(ringL: FloatRingBuffer, ringR: FloatRingBuffer) {
        self.ringL = ringL; self.ringR = ringR
    }
}

/// Passed to the output AUHAL render callback (EQ → headphones)
private final class OutputCBCtx {
    let eqUnit: AudioUnit
    let volumePtr: UnsafeMutablePointer<Float>
    init(eqUnit: AudioUnit, volumePtr: UnsafeMutablePointer<Float>) {
        self.eqUnit = eqUnit; self.volumePtr = volumePtr
    }
}

// MARK: - C-callable callbacks

/// Input AUHAL: capture from BlackHole, write to ring buffers
private func inputCB(
    _ ref: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ ts: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32, _ frames: UInt32,
    _: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let c = Unmanaged<InputCBCtx>.fromOpaque(ref).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(c.renderBuf)
    for i in 0..<2 { abl[i].mDataByteSize = frames * 4 }
    let s = AudioUnitRender(c.au, flags, ts, 1, frames, c.renderBuf)
    if s == noErr {
        if let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            c.ringL.write(p, count: Int(frames))
        }
        if let p = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            c.ringR.write(p, count: Int(frames))
        }
    }
    return s
}

/// EQ input callback: read from ring buffers to feed the EQ
private func eqInputCB(
    _ ref: UnsafeMutableRawPointer,
    _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UInt32, _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let c = Unmanaged<EQInputCtx>.fromOpaque(ref).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let n = Int(frames)
    if abl.count >= 1, let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
        let got = c.ringL.read(p, count: n)
        if got < n { p.advanced(by: got).initialize(repeating: 0, count: n - got) }
    }
    if abl.count >= 2, let p = abl[1].mData?.assumingMemoryBound(to: Float.self) {
        let got = c.ringR.read(p, count: n)
        if got < n { p.advanced(by: got).initialize(repeating: 0, count: n - got) }
    }
    return noErr
}

/// Output AUHAL callback: pull from EQ, apply volume, send to headphones
private func outputCB(
    _ ref: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ ts: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32, _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let c = Unmanaged<OutputCBCtx>.fromOpaque(ref).takeUnretainedValue()

    var renderFlags = AudioUnitRenderActionFlags(rawValue: 0)
    let s = AudioUnitRender(c.eqUnit, &renderFlags, ts, 0, frames, ioData)

    // Apply volume
    let vol = c.volumePtr.pointee
    if s == noErr, vol < 1.0 {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for i in 0..<Int(abl.count) {
            if let p = abl[i].mData?.assumingMemoryBound(to: Float.self) {
                for j in 0..<Int(frames) { p[j] *= vol }
            }
        }
    }
    return s
}

// MARK: - AudioEngine

@Observable
final class AudioEngine {
    var bands: [EQBand] = makeDefaultBands()
    var isRunning = false
    var selectedInput: AudioDevice?
    var selectedOutput: AudioDevice?
    var volume: Float = 1.0
    var errorMessage: String?

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var eqUnit: AudioUnit?
    private var ringL: FloatRingBuffer?
    private var ringR: FloatRingBuffer?
    private var volumePtr: UnsafeMutablePointer<Float>?
    private var inputCtx: Unmanaged<InputCBCtx>?
    private var eqCtx: Unmanaged<EQInputCtx>?
    private var outputCtx: Unmanaged<OutputCBCtx>?
    private var previousSystemOutputID: AudioDeviceID?
    private var previousSystemInputID: AudioDeviceID?

    init() {
        selectedInput = AudioDeviceManager.findBlackHole()
        selectedOutput = AudioDeviceManager.preferredOutputDevice()
        loadState()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    // MARK: - Start / Stop

    func start() {
        guard let input = selectedInput else {
            errorMessage = "No input device selected. Is BlackHole installed?"
            return
        }
        guard let output = selectedOutput else {
            errorMessage = "No output device selected."
            return
        }

        do {
            previousSystemOutputID = AudioDeviceManager.defaultOutputDeviceID()
            previousSystemInputID = AudioDeviceManager.defaultInputDeviceID()

            let rate = AudioDeviceManager.nominalSampleRate(output.id) ?? 48_000
            AudioDeviceManager.setNominalSampleRate(input.id, rate: rate)
            Thread.sleep(forTimeInterval: 0.1)

            ringL = FloatRingBuffer(capacity: 16_384)
            ringR = FloatRingBuffer(capacity: 16_384)
            volumePtr = .allocate(capacity: 1)
            volumePtr!.initialize(to: volume)

            try setupInputAU(device: input.id, sampleRate: rate)
            try setupEQ(sampleRate: rate)
            try setupOutputAU(device: output.id, sampleRate: rate)

            applyAllBands()

            // Start output first (it will pull silence until input feeds the ring buffer)
            try check(AudioOutputUnitStart(outputUnit!))
            try check(AudioOutputUnitStart(inputUnit!))

            // Redirect system output to BlackHole so apps send audio there
            AudioDeviceManager.setDefaultOutputDevice(input.id)

            isRunning = true
            errorMessage = nil
        } catch {
            teardown()
            restoreSystemDevices()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        if let u = inputUnit { AudioOutputUnitStop(u) }
        if let u = outputUnit { AudioOutputUnitStop(u) }
        teardown()
        isRunning = false
        restoreSystemDevices()
        saveState()
    }

    // MARK: - Band updates

    func applyBand(at index: Int) {
        guard let eq = eqUnit else { return }
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
    }

    func applyAllBands() { for i in bands.indices { applyBand(at: i) } }

    func applyPreset(_ preset: EQPreset) {
        guard preset.bands.count == bands.count else { return }
        bands = preset.bands
        applyAllBands()
    }

    func setVolume(_ v: Float) {
        volume = v
        volumePtr?.pointee = v
    }

    // MARK: - Persistence

    func saveState() {
        if let data = try? JSONEncoder().encode(bands) {
            UserDefaults.standard.set(data, forKey: "paraeq.bands")
        }
        UserDefaults.standard.set(volume, forKey: "paraeq.volume")
        if let uid = selectedOutput?.uid {
            UserDefaults.standard.set(uid, forKey: "paraeq.outputUID")
        }
    }

    func loadState() {
        if let data = UserDefaults.standard.data(forKey: "paraeq.bands"),
           let saved = try? JSONDecoder().decode([EQBand].self, from: data),
           saved.count == bands.count { bands = saved }
        let v = UserDefaults.standard.float(forKey: "paraeq.volume")
        if v > 0 { volume = v }
        if let uid = UserDefaults.standard.string(forKey: "paraeq.outputUID") {
            selectedOutput = AudioDeviceManager.outputDevices().first { $0.uid == uid }
                ?? selectedOutput
        }
    }

    // MARK: - Private – Input AUHAL (reads from BlackHole)

    private func setupInputAU(device: AudioDeviceID, sampleRate: Double) throws {
        let au = try makeHALUnit()

        // Enable input on element 1, disable output on element 0
        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &on, 4))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &off, 4))

        var devID = device
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)))

        var fmt = stereoFormat(sampleRate)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var maxFrames: UInt32 = 4096; var sz: UInt32 = 4
        AudioUnitGetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxFrames, &sz)

        let ctx = InputCBCtx(au: au, ringL: ringL!, ringR: ringR!,
                             maxFrames: max(maxFrames, 4096))
        let um = Unmanaged.passRetained(ctx)
        inputCtx = um

        var cb = AURenderCallbackStruct(inputProc: inputCB,
                                        inputProcRefCon: um.toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check(AudioUnitInitialize(au))
        inputUnit = au
    }

    // MARK: - Private – N-Band EQ (standalone AudioUnit)

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

        var numBands = UInt32(bands.count)
        try check(AudioUnitSetProperty(au, 2200, // kAUNBandEQProperty_NumberOfBands
            kAudioUnitScope_Global, 0, &numBands, 4))

        var fmt = stereoFormat(sampleRate)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        // EQ pulls input from ring buffer via render callback
        let ctx = EQInputCtx(ringL: ringL!, ringR: ringR!)
        let um = Unmanaged.passRetained(ctx)
        eqCtx = um

        var cb = AURenderCallbackStruct(inputProc: eqInputCB,
                                        inputProcRefCon: um.toOpaque())
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check(AudioUnitInitialize(au))
        eqUnit = au
    }

    // MARK: - Private – Output AUHAL (writes to headphones)

    private func setupOutputAU(device: AudioDeviceID, sampleRate: Double) throws {
        let au = try makeHALUnit()

        // Disable input on element 1 (output is enabled by default)
        var off: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &off, 4))

        var devID = device
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)))

        var fmt = stereoFormat(sampleRate)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        // Output pulls from EQ via render callback
        let ctx = OutputCBCtx(eqUnit: eqUnit!, volumePtr: volumePtr!)
        let um = Unmanaged.passRetained(ctx)
        outputCtx = um

        var cb = AURenderCallbackStruct(inputProc: outputCB,
                                        inputProcRefCon: um.toOpaque())
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check(AudioUnitInitialize(au))
        outputUnit = au
    }

    // MARK: - Private – helpers

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.noAudioUnit
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au))
        guard let au else { throw EngineError.noAudioUnit }
        return au
    }

    private func stereoFormat(_ sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    private func teardown() {
        if let u = inputUnit {
            AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
            inputUnit = nil
        }
        if let u = eqUnit {
            AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
            eqUnit = nil
        }
        if let u = outputUnit {
            AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
            outputUnit = nil
        }
        inputCtx?.release(); inputCtx = nil
        eqCtx?.release(); eqCtx = nil
        outputCtx?.release(); outputCtx = nil
        ringL = nil; ringR = nil
        if let p = volumePtr { p.deallocate(); volumePtr = nil }
    }

    private func restoreSystemDevices() {
        if let p = previousSystemOutputID {
            AudioDeviceManager.setDefaultOutputDevice(p)
            previousSystemOutputID = nil
        }
        if let p = previousSystemInputID {
            AudioDeviceManager.setDefaultInputDevice(p)
            previousSystemInputID = nil
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw EngineError.osStatus(status) }
    }

    enum EngineError: LocalizedError {
        case noAudioUnit
        case badFormat
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noAudioUnit: "Could not access audio unit"
            case .badFormat: "Invalid audio format from input device"
            case .osStatus(let s): "Audio error \(s)"
            }
        }
    }
}
