import SwiftUI
import UniformTypeIdentifiers

struct EQView: View {
    @Bindable var engine: AudioEngine
    @State private var presetManager = PresetManager()

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            deviceSection
            if engine.isRunning {
                LevelMeterView(peakL: engine.peakL, peakR: engine.peakR)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            if let msg = warningMessage {
                warningBanner(msg)
            }
            if let msg = importWarning {
                warningBanner(msg)
            }
            Divider()
            presetSection
            Divider()
            FrequencyResponseView(bands: engine.activeBands)
            Divider()
            bandList
            Divider()
            footerSection
        }
        .frame(width: 440, height: 764)
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
                if engine.isRunning { engine.stop(rememberOff: true) } else { engine.start() }
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
                Text("Output").frame(width: 50, alignment: .leading)
                Picker("", selection: $engine.selectedOutput) {
                    Text("System Default").tag(AudioDevice?.none)
                    ForEach(AudioDeviceManager.outputDevices()) { d in
                        Text(d.name).tag(AudioDevice?.some(d))
                    }
                }
                .labelsHidden()
                .onChange(of: engine.selectedOutput) { _, _ in
                    engine.outputSelectionChanged()
                }
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
                Text("Bal").frame(width: 50, alignment: .leading)
                Slider(value: Binding(
                    get: { engine.balance },
                    set: { engine.setBalance(Float($0)) }
                ), in: -1...1)
                Text(engine.balance == 0 ? "C"
                     : String(format: "%@%.0f%%", engine.balance < 0 ? "L" : "R",
                              abs(engine.balance) * 100))
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
                    .font(.caption)
            }
            HStack {
                Text("FIR").frame(width: 50, alignment: .leading)
                if let name = engine.impulseResponseName {
                    Text(name).font(.caption).lineLimit(1)
                    Button {
                        engine.clearImpulseResponse()
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                } else if let nodes = engine.graphicEQNodes {
                    Text("GraphicEQ (\(nodes.count) pts)").font(.caption)
                    Button {
                        engine.setGraphicEQ(nil)
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                } else {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Load IR…") { openIRPanel() }
                    .font(.caption)
            }
            HStack {
                Text("XFeed").frame(width: 50, alignment: .leading)
                Picker("", selection: Binding(
                    get: { engine.crossfeedMode },
                    set: { engine.setCrossfeedMode($0) }
                )) {
                    ForEach(CrossfeedMode.allCases) { m in
                        Text(m.name).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
        engine.errorMessage
    }

    @State private var importWarning: String?

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
    @State private var showingSavePopover = false
    @State private var newPresetName = ""

    private var presetSection: some View {
        HStack {
            Text("Preset").frame(width: 50, alignment: .leading)
            Picker("", selection: $selectedPresetID) {
                ForEach(EQPreset.builtIn) { p in
                    Text(p.name).tag(p.id)
                }
                if !presetManager.customPresets.isEmpty {
                    Divider()
                    ForEach(presetManager.customPresets) { p in
                        Text(p.name).tag(p.id)
                    }
                }
            }
            .labelsHidden()
            .onChange(of: selectedPresetID) { _, newID in
                if let preset = presetManager.allPresets.first(where: { $0.id == newID }) {
                    engine.applyPreset(preset)
                }
            }

            // Save button
            Button {
                newPresetName = ""
                showingSavePopover = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingSavePopover) {
                VStack(spacing: 8) {
                    Text("Save Preset").font(.headline)
                    TextField("Name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    HStack {
                        Button("Cancel") { showingSavePopover = false }
                        Button("Save") {
                            let name = newPresetName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            let preampVal: Float? = engine.autoPreamp ? nil : engine.preamp
                            presetManager.save(name: name, bands: engine.activeBands, preamp: preampVal)
                            selectedPresetID = presetManager.customPresets.last!.id
                            showingSavePopover = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding()
            }

            // Import button
            Button {
                openImportPanel()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)

            // Delete button (only for custom presets)
            if let selected = presetManager.customPresets.first(where: { $0.id == selectedPresetID }) {
                Button {
                    presetManager.delete(selected)
                    selectedPresetID = "flat"
                    engine.applyPreset(.flat)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Import handling

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ Profile"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .floating

        guard panel.runModal() == .OK, let url = panel.url else { return }

        importWarning = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importWarning = "Could not read file"
            return
        }

        // GraphicEQ profile → minimum-phase FIR stage
        if let nodes = AutoEQParser.parseGraphicEQ(text) {
            engine.setGraphicEQ(nodes)
            return
        }

        let parsed = AutoEQParser.parse(text)
        if parsed.bands.isEmpty {
            importWarning = "No filters found in file"
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let preset = EQPreset(
            id: UUID().uuidString,
            name: name,
            bands: parsed.bands,
            preamp: parsed.preamp
        )
        presetManager.addImported(preset)
        selectedPresetID = preset.id
        engine.applyPreset(preset)
    }

    private func openIRPanel() {
        let panel = NSOpenPanel()
        panel.title = "Load Impulse Response"
        panel.allowedContentTypes = [.audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .floating
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.loadImpulseResponse(url: url)
    }

    // MARK: - Band list

    private var bandList: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Binding(
                    get: { engine.channelMode },
                    set: { engine.setChannelMode($0) }
                )) {
                    ForEach(ChannelMode.allCases) { m in
                        Text(m.name).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if engine.channelMode != .linked {
                    Picker("", selection: $engine.editingB) {
                        Text(engine.channelMode.channelNames.0).tag(false)
                        Text(engine.channelMode.channelNames.1).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Menu("\(engine.activeBands.count) Bands") {
                    ForEach(BandLayout.allCases) { layout in
                        Button(layout.name) {
                            engine.setLayout(layout)
                            selectedPresetID = "flat"
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button {
                    engine.addBand()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add band")
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(engine.activeBands.indices, id: \.self) { i in
                        BandRow(
                            index: i,
                            band: bandBinding(i),
                            onChange: { engine.applyBand(at: i) }
                        )
                        .contextMenu {
                            Button("Remove Band", role: .destructive) {
                                engine.removeBand(at: i)
                            }
                            .disabled(engine.activeBands.count <= 1)
                        }
                        if i < engine.activeBands.count - 1 {
                            Divider().padding(.horizontal)
                        }
                    }
                }
            }
        }
    }

    private func bandBinding(_ i: Int) -> Binding<EQBand> {
        Binding(
            get: { i < engine.activeBands.count ? engine.activeBands[i] : EQBand() },
            set: { if i < engine.activeBands.count { engine.activeBands[i] = $0 } }
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Reset") {
                engine.bands = makeDefaultBands()
                engine.bandsB = makeDefaultBands()
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
                    // Gain (hidden for types where gain doesn't apply)
                    if band.filterType.usesGain {
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
                    }
                    // Q (hidden for fixed-Q crossover types)
                    if band.filterType.usesQ {
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
