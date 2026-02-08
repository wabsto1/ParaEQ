import SwiftUI

struct EQView: View {
    @Bindable var engine: AudioEngine

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            deviceSection
            if let msg = warningMessage {
                warningBanner(msg)
            }
            Divider()
            presetSection
            Divider()
            FrequencyResponseView(bands: engine.bands)
            Divider()
            bandList
            Divider()
            footerSection
        }
        .frame(width: 440, height: 680)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
                .font(.title2)
            Text("ParaEQ")
                .font(.headline)
            Spacer()
            Button(engine.isRunning ? "Stop" : "Start") {
                if engine.isRunning { engine.stop() } else { engine.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Devices

    private var deviceSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Input").frame(width: 50, alignment: .leading)
                Picker("", selection: $engine.selectedInput) {
                    Text("None").tag(AudioDevice?.none)
                    ForEach(AudioDeviceManager.inputDevices()) { d in
                        Text(d.name).tag(AudioDevice?.some(d))
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("Output").frame(width: 50, alignment: .leading)
                Picker("", selection: $engine.selectedOutput) {
                    Text("None").tag(AudioDevice?.none)
                    ForEach(AudioDeviceManager.outputDevices()) { d in
                        Text(d.name).tag(AudioDevice?.some(d))
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("Vol").frame(width: 50, alignment: .leading)
                Slider(value: Binding(
                    get: { engine.volume },
                    set: { engine.setVolume(Float($0)) }
                ), in: 0...1)
                Text("\(Int(engine.volume * 100))%")
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
            }
            HStack {
                Text("Pre").frame(width: 50, alignment: .leading)
                Toggle("Auto", isOn: Binding(
                    get: { engine.autoPreamp },
                    set: { newVal in
                        engine.autoPreamp = newVal
                        if newVal { engine.computeAutoPreamp() }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                if engine.autoPreamp {
                    Spacer()
                } else {
                    Slider(value: Binding(
                        get: { engine.preamp },
                        set: { engine.setPreamp(Float($0)) }
                    ), in: -24...12, step: 0.5)
                }
                Text(String(format: "%+.1f dB", engine.preamp))
                    .frame(width: 56, alignment: .trailing)
                    .monospacedDigit()
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Warning

    private var warningMessage: String? {
        if engine.selectedInput == nil {
            return "BlackHole not found. Install: brew install blackhole-2ch"
        }
        if let err = engine.errorMessage {
            return err
        }
        return nil
    }

    private func warningBanner(_ msg: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(msg).font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Presets

    @State private var selectedPresetID: String = "flat"

    private var presetSection: some View {
        HStack {
            Text("Preset").frame(width: 50, alignment: .leading)
            Picker("", selection: $selectedPresetID) {
                ForEach(EQPreset.builtIn) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .onChange(of: selectedPresetID) { _, newID in
                if let preset = EQPreset.builtIn.first(where: { $0.id == newID }) {
                    engine.applyPreset(preset)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Band list

    private var bandList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(engine.bands.indices, id: \.self) { i in
                    BandRow(
                        index: i,
                        band: bandBinding(i),
                        onChange: { engine.applyBand(at: i) }
                    )
                    if i < engine.bands.count - 1 {
                        Divider().padding(.horizontal)
                    }
                }
            }
        }
    }

    private func bandBinding(_ i: Int) -> Binding<EQBand> {
        Binding(
            get: { engine.bands[i] },
            set: { engine.bands[i] = $0 }
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Reset") {
                engine.bands = makeDefaultBands()
                engine.applyAllBands()
                selectedPresetID = "flat"
            }
            Spacer()
            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Band Row

struct BandRow: View {
    let index: Int
    @Binding var band: EQBand
    var onChange: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Summary row — always visible
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Toggle("", isOn: $band.enabled)
                        .labelsHidden()
                        .onChange(of: band.enabled) { _, _ in onChange() }

                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .frame(width: 18)

                    Text(band.filterType.name)
                        .font(.caption)
                        .frame(width: 58, alignment: .leading)

                    Text(band.frequencyLabel)
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 40, alignment: .trailing)
                    Text("Hz")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(band.gainLabel)
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 36, alignment: .trailing)
                    Text("dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Q")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(band.qLabel)
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 34, alignment: .trailing)

                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)

            // Expanded controls
            if isExpanded {
                VStack(spacing: 6) {
                    // Filter type
                    HStack {
                        Text("Type")
                            .font(.caption)
                            .frame(width: 36, alignment: .leading)
                        Picker("", selection: $band.filterType) {
                            ForEach(FilterType.allCases) { t in
                                Text(t.name).tag(t)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: band.filterType) { _, _ in onChange() }
                    }
                    // Frequency (logarithmic)
                    HStack {
                        Text("Freq")
                            .font(.caption)
                            .frame(width: 36, alignment: .leading)
                        Slider(
                            value: logBinding(
                                value: $band.frequency,
                                range: 20...20000
                            ),
                            in: log10(20)...log10(20000)
                        )
                        .onChange(of: band.frequency) { _, _ in onChange() }
                        Text("\(band.frequencyLabel) Hz")
                            .font(.caption).monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    // Gain
                    HStack {
                        Text("Gain")
                            .font(.caption)
                            .frame(width: 36, alignment: .leading)
                        Slider(value: $band.gain, in: -24...24, step: 0.1)
                            .onChange(of: band.gain) { _, _ in onChange() }
                        Text("\(band.gainLabel) dB")
                            .font(.caption).monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    // Q (logarithmic)
                    HStack {
                        Text("Q")
                            .font(.caption)
                            .frame(width: 36, alignment: .leading)
                        Slider(
                            value: logBinding(
                                value: $band.q,
                                range: 0.1...30
                            ),
                            in: log10(0.1)...log10(30)
                        )
                        .onChange(of: band.q) { _, _ in onChange() }
                        Text(band.qLabel)
                            .font(.caption).monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .opacity(band.enabled ? 1.0 : 0.4)
            }
        }
    }

    /// Create a logarithmic binding for a Slider
    private func logBinding(value: Binding<Float>, range: ClosedRange<Float>) -> Binding<Double> {
        Binding<Double>(
            get: { log10(Double(max(value.wrappedValue, range.lowerBound))) },
            set: { value.wrappedValue = Float(pow(10, $0)) }
        )
    }
}
