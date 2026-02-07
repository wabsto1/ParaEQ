import AppKit
import AVFoundation
import CoreAudio
import Observation

@Observable
final class AudioEngine {
    var bands: [EQBand] = makeDefaultBands()
    var isRunning = false
    var selectedInput: AudioDevice?
    var selectedOutput: AudioDevice?
    var volume: Float = 1.0
    var errorMessage: String?

    private var engine: AVAudioEngine?
    private var eq: AVAudioUnitEQ?
    private var previousSystemOutputID: AudioDeviceID?

    init() {
        selectedInput = AudioDeviceManager.findBlackHole()
        selectedOutput = AudioDeviceManager.preferredOutputDevice()
        loadState()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
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
            // Remember current system output so we can restore later
            previousSystemOutputID = AudioDeviceManager.defaultOutputDeviceID()

            // Route system audio into BlackHole
            AudioDeviceManager.setDefaultOutputDevice(input.id)

            try buildAndStart(inputID: input.id, outputID: output.id)
            isRunning = true
            errorMessage = nil
        } catch {
            restoreSystemOutput()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        engine?.stop()
        if let eq { engine?.detach(eq) }
        engine = nil
        eq = nil
        isRunning = false
        restoreSystemOutput()
        saveState()
    }

    // MARK: - Band updates

    func applyBand(at index: Int) {
        guard let eqBand = eq?.bands[index] else { return }
        let band = bands[index]
        eqBand.filterType = band.filterType.avType
        eqBand.frequency = band.frequency
        eqBand.gain = band.enabled ? band.gain : 0
        eqBand.bandwidth = band.bandwidth
        eqBand.bypass = !band.enabled
    }

    func applyAllBands() {
        for i in bands.indices { applyBand(at: i) }
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.bands.count == bands.count else { return }
        bands = preset.bands
        applyAllBands()
    }

    func setVolume(_ v: Float) {
        volume = v
        engine?.mainMixerNode.outputVolume = v
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
           saved.count == bands.count {
            bands = saved
        }
        let v = UserDefaults.standard.float(forKey: "paraeq.volume")
        if v > 0 { volume = v }

        if let uid = UserDefaults.standard.string(forKey: "paraeq.outputUID") {
            selectedOutput = AudioDeviceManager.outputDevices().first { $0.uid == uid }
                ?? selectedOutput
        }
    }

    // MARK: - Private

    private func buildAndStart(inputID: AudioDeviceID, outputID: AudioDeviceID) throws {
        // Match sample rates between input and output devices
        let outputRate = AudioDeviceManager.nominalSampleRate(outputID) ?? 48000
        AudioDeviceManager.setNominalSampleRate(inputID, rate: outputRate)
        // Brief pause so CoreAudio picks up the rate change
        Thread.sleep(forTimeInterval: 0.1)

        let eng = AVAudioEngine()
        let numBands = bands.count
        let eqUnit = AVAudioUnitEQ(numberOfBands: numBands)

        // Set input device (BlackHole)
        try setDeviceOn(eng.inputNode, deviceID: inputID)

        // Set output device (headphones)
        try setDeviceOn(eng.outputNode, deviceID: outputID)

        // Build a standard stereo format at the matched sample rate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!

        // Wire: input → EQ → mixer → output
        eng.attach(eqUnit)
        eng.connect(eng.inputNode, to: eqUnit, format: fmt)
        eng.connect(eqUnit, to: eng.mainMixerNode, format: fmt)

        eng.mainMixerNode.outputVolume = volume

        self.engine = eng
        self.eq = eqUnit
        applyAllBands()

        eng.prepare()
        try eng.start()

        // Re-apply after start to ensure parameters stick
        applyAllBands()
    }

    private func setDeviceOn(_ node: AVAudioIONode, deviceID: AudioDeviceID) throws {
        guard let au = node.audioUnit else { throw EngineError.noAudioUnit }
        var id = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw EngineError.osStatus(status) }
    }

    private func restoreSystemOutput() {
        if let prev = previousSystemOutputID {
            AudioDeviceManager.setDefaultOutputDevice(prev)
            previousSystemOutputID = nil
        }
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
