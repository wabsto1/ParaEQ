import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct EQView: View {
    @Bindable var engine: AudioEngine
    var appMixer: AppMixer? = nil
    /// true when hosted in the resizable pop-out window rather than the
    /// menu-bar panel (flexible layout, no pop-out button).
    var inWindow = false
    @State private var presetManager = PresetManager()
    @State private var hintState = HintState()
    @State private var selectedBand: Int?
    @State private var keyMonitor: Any?
    @State private var hostWindow: NSWindow?
    @Environment(\.openWindow) private var openWindow
    /// Graph gain range setting; 0 = auto-scale to the current curve.
    @AppStorage("paraeq.graphSpan") private var graphSpanSetting: Double = 24
    /// Show band width as octaves instead of Q.
    @AppStorage("paraeq.bandwidthOct") private var bandwidthOct = false

    var body: some View {
        if inWindow {
            core.frame(minWidth: 440, minHeight: 720)
        } else {
            core.frame(width: 440, height: 816)
        }
    }

    private var core: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            deviceSection
            if engine.isRunning {
                LevelMeterView(engine: engine)
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
            if let appMixer {
                Divider()
                AppMixerView(mixer: appMixer)
            }
            Divider()
            graphControls
            FrequencyResponseView(
                bands: Binding(
                    get: { engine.activeBands },
                    set: { engine.activeBands = $0 }
                ),
                selectedBand: $selectedBand,
                dbSpan: effectiveGraphSpan,
                engine: engine,
                flexibleHeight: inWindow
            ) {
                engine.applyAllBands()
            }
            Divider()
            bandList
            Divider()
            hintBar
            Divider()
            footerSection
        }
        .environment(hintState)
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            engine.presetLookup = { [weak presetManager] id in
                presetManager?.allPresets.first { $0.id == id }
            }
            registerHotkeys()
            installKeyMonitor()
            outputDevices = AudioDeviceManager.outputDevices()
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: presetManager.customPresets.count) { _, _ in
            registerHotkeys()
        }
        .onChange(of: engine.activeBands.count) { _, _ in
            selectedBand = nil
        }
        .onChange(of: engine.activeBands, initial: true) { _, newBands in
            peakAbsDB = FrequencyResponse.peakAbsGainDB(for: newBands)
        }
        .onChange(of: engine.deviceListGeneration) { _, _ in
            outputDevices = AudioDeviceManager.outputDevices()
        }
        .onChange(of: engine.balance, initial: true) { _, b in
            balanceText = BalanceEntry.label(for: b)
        }
    }

    // MARK: - Graph controls (undo/redo, spectrum toggle, gain range)

    /// Peak |dB| of the current curve, recomputed only on band edits (not on
    /// every 30 fps meter tick — the auto range runs a 200-point curve).
    @State private var peakAbsDB: Double = 0
    /// Cached HAL device list; enumerating in body would run per meter tick.
    @State private var outputDevices: [AudioDevice] = []
    /// Cached SMAppService status; querying it is a blocking XPC call and the
    /// toggle's binding getter runs on every body evaluation.
    @State private var startAtLogin = false
    /// Editable balance readout ("C", "L20", "R7"); committed on Return.
    @State private var balanceText = "C"

    private func commitBalanceText() {
        if let v = BalanceEntry.parse(balanceText) {
            engine.setBalance(v)
        }
        balanceText = BalanceEntry.label(for: engine.balance)
    }

    private var effectiveGraphSpan: Double {
        graphSpanSetting == 0
            ? GraphRange.auto(forPeakAbsDB: peakAbsDB)
            : graphSpanSetting
    }

    private var graphControls: some View {
        HStack(spacing: 10) {
            Button { engine.undoEdit() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!engine.canUndo)
            .helpHint("Undo the last EQ edit (⌘Z)")
            Button { engine.redoEdit() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!engine.canRedo)
            .helpHint("Redo (⇧⌘Z)")
            Spacer()
            if engine.isRunning {
                Button { engine.setShowSpectrum(!engine.showSpectrum) } label: {
                    Image(systemName: "waveform")
                        .foregroundStyle(engine.showSpectrum
                            ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .helpHint("Live spectrum: cyan = source audio, orange = after EQ")
            }
            Menu(graphSpanSetting == 0 ? "Auto" : "±\(Int(graphSpanSetting)) dB") {
                Button("Auto") { graphSpanSetting = 0 }
                ForEach(GraphRange.choices, id: \.self) { r in
                    Button("±\(Int(r)) dB") { graphSpanSetting = r }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .helpHint("Gain range of the response graph (Auto fits the current curve)")
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - Keyboard editing (local monitor while the panel is open)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Returns true when the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Local monitors are app-wide; when the panel AND the pop-out window
        // are both open, two EQViews are alive — only the instance whose
        // window received the event may handle it, or ⌘Z would fire twice.
        guard let window = event.window, window === hostWindow else { return false }
        // Never steal keys from an active text field (preset name etc.).
        if window.firstResponder is NSTextView { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", mods == .command { engine.undoEdit(); return true }
        if key == "z", mods == [.command, .shift] { engine.redoEdit(); return true }
        if key == "b", mods == .command, engine.isRunning {
            engine.setBypassed(!engine.bypassed)
            return true
        }
        switch event.keyCode {
        case 48:   // Tab / ⇧Tab — cycle band selection
            guard mods.isDisjoint(with: [.command, .option, .control]) else { return false }
            cycleSelection(backward: mods.contains(.shift))
            return true
        case 123, 124, 125, 126:   // arrows — nudge the selected band
            guard mods.isDisjoint(with: [.command, .option, .control]),
                  let i = selectedBand, engine.activeBands.indices.contains(i)
            else { return false }
            nudgeBand(i, keyCode: event.keyCode, fine: mods.contains(.shift))
            return true
        default:
            return false
        }
    }

    private func cycleSelection(backward: Bool) {
        let count = engine.activeBands.count
        guard count > 0 else { return }
        if let current = selectedBand {
            selectedBand = ((current + (backward ? -1 : 1)) + count) % count
        } else {
            selectedBand = backward ? count - 1 : 0
        }
    }

    /// ↑/↓ = gain ±0.5 dB, ←/→ = frequency ∓1 semitone; ⇧ for fine steps.
    private func nudgeBand(_ i: Int, keyCode: UInt16, fine: Bool) {
        var band = engine.activeBands[i]
        let freqStep = Float(pow(2.0, fine ? 1.0 / 48.0 : 1.0 / 12.0))
        switch keyCode {
        case 126 where band.filterType.usesGain:
            band.gain = min(band.gain + (fine ? 0.1 : 0.5), 24)
        case 125 where band.filterType.usesGain:
            band.gain = max(band.gain - (fine ? 0.1 : 0.5), -24)
        case 124:
            band.frequency = min(band.frequency * freqStep, 20000)
        case 123:
            band.frequency = max(band.frequency / freqStep, 20)
        default:
            return
        }
        engine.activeBands[i] = band
        engine.applyAllBands()
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
                .font(.title2)
            Text("ParaEQ")
                .font(.headline)
            if !inWindow {
                Button {
                    openWindow(id: "popout")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .helpHint("Open ParaEQ in a resizable window")
            }
            Spacer()
            if engine.isRunning {
                Button {
                    engine.setBypassed(!engine.bypassed)
                } label: {
                    Text(engine.bypassed ? "Bypassed" : "A/B")
                        .frame(width: 62)
                }
                .tint(engine.bypassed ? .orange : nil)
                .buttonStyle(.bordered)
                .helpHint("Toggle EQ bypass for A/B comparison")
            }
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
                    ForEach(outputDevices) { d in
                        Text(d.name).tag(AudioDevice?.some(d))
                    }
                }
                .labelsHidden()
                .onChange(of: engine.selectedOutput) { _, _ in
                    engine.outputSelectionChanged()
                }
                .helpHint("Playback device. System Default follows macOS routing automatically")
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
                TextField("C", text: $balanceText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 36)
                    .monospacedDigit()
                    .font(.caption)
                    .onSubmit(commitBalanceText)
                    .helpHint("Type 0 or C for center, L20/R20 to bias a side, then press Return")
                Button {
                    openWindow(id: "balance-calibration")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "ear.badge.waveform")
                }
                .buttonStyle(.borderless)
                .disabled(!engine.isRunning)
                .helpHint("Calibrate L/R balance with the Mac's microphone (hold each earcup to the mic)")
            }
            HStack {
                Text("FIR").frame(width: 50, alignment: .leading)
                if let name = engine.impulseResponseName {
                    Text(name).font(.caption).lineLimit(1)
                    Button {
                        engine.clearImpulseResponse()
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .helpHint("Remove the loaded impulse response")
                } else if let nodes = engine.graphicEQNodes {
                    Text("GraphicEQ (\(nodes.count) pts)").font(.caption)
                    Button {
                        engine.setGraphicEQ(nil)
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .helpHint("Remove the GraphicEQ curve")
                } else {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Load IR…") { openIRPanel() }
                    .font(.caption)
                    .helpHint("Load an impulse response file for convolution (room/headphone correction)")
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
                .helpHint("Headphone crossfeed: bleeds low-passed opposite-channel audio into each ear, like speakers in a room")
            }
            HStack {
                Text("Pre").frame(width: 50, alignment: .leading)
                Toggle("Auto", isOn: Binding(
                    get: { engine.autoPreamp },
                    set: { engine.setAutoPreamp($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .helpHint("Auto-preamp lowers gain to exactly offset your largest EQ boost, preventing clipping")
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
    @State private var showingAutoEQPicker = false
    @State private var newPresetName = ""

    /// The current curve no longer matches the selected preset.
    private var presetEdited: Bool {
        guard let preset = presetManager.allPresets.first(where: { $0.id == selectedPresetID })
        else { return false }
        return engine.bands != preset.bands
    }

    private var isPinnedToCurrentDevice: Bool {
        guard let uid = engine.currentOutputUID else { return false }
        return engine.deviceProfile(forUID: uid) == selectedPresetID
    }

    private func togglePin() {
        guard let uid = engine.currentOutputUID else { return }
        engine.assignDeviceProfile(
            presetID: isPinnedToCurrentDevice ? nil : selectedPresetID, forUID: uid)
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.title = "Export Equalizer APO Preset"
        panel.nameFieldStringValue = "ParaEQ ParametricEQ.txt"
        panel.allowedContentTypes = [.plainText]
        panel.level = .floating
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? engine.exportEqualizerAPOText().write(to: url, atomically: true, encoding: .utf8)
    }

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

            if presetEdited {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .helpHint("Curve differs from the selected preset — use Save to keep it")
            }

            // Save button
            Button {
                newPresetName = ""
                showingSavePopover = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .helpHint("Save the current curve as a preset")
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
            .helpHint("Import Equalizer APO / AutoEQ file")

            // Export button (Equalizer APO ParametricEQ.txt)
            Button {
                exportPreset()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .helpHint("Export as Equalizer APO ParametricEQ.txt")

            // AutoEQ online database picker
            Button {
                showingAutoEQPicker = true
            } label: {
                Image(systemName: "headphones")
            }
            .buttonStyle(.borderless)
            .helpHint("Browse the AutoEQ headphone database")
            .sheet(isPresented: $showingAutoEQPicker) {
                AutoEQPickerView { name, parsed in
                    let preset = EQPreset(id: UUID().uuidString, name: name,
                                          bands: parsed.bands, preamp: parsed.preamp)
                    presetManager.addImported(preset)
                    selectedPresetID = preset.id
                    engine.applyPreset(preset)
                }
            }

            // Pin: assign the selected preset to the current output device
            Button {
                togglePin()
            } label: {
                Image(systemName: isPinnedToCurrentDevice ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .helpHint("Auto-apply this preset when the current output device is active")

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
                .helpHint("Delete this preset")
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

    /// ⌘⌃1…9 activate presets in menu order.
    private func registerHotkeys() {
        let presets = presetManager.allPresets
        HotkeyManager.shared.registerPresetHotkeys(count: presets.count)
        HotkeyManager.shared.onHotkey = { index in
            let all = presetManager.allPresets
            guard all.indices.contains(index) else { return }
            selectedPresetID = all[index].id
            engine.applyPreset(all[index])
        }
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
                .helpHint("Channel mode: one EQ for both channels (Stereo), independent Left/Right, or Mid/Side")
                if engine.channelMode != .linked {
                    Picker("", selection: $engine.editingB) {
                        Text(engine.channelMode.channelNames.0).tag(false)
                        Text(engine.channelMode.channelNames.1).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .helpHint("Select which channel's bands to edit")
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
                .helpHint("Switch band layout (5/10/15/31 ISO bands — resets gains)")
                Spacer()
                Button {
                    engine.addBand()
                    selectedBand = engine.activeBands.count - 1
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .helpHint("Add a band in the largest gap of the current curve")
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
                            isSelected: selectedBand == i,
                            bandwidthOct: $bandwidthOct,
                            onChange: { engine.applyBand(at: i) },
                            onSelect: { selectedBand = i }
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

    // MARK: - Hint bar (hover descriptions; native tooltips are unreliable
    // in MenuBarExtra panels)

    private var hintBar: some View {
        Text(hintState.text ?? "Hover any control for a description")
            .font(.caption2)
            .foregroundStyle(hintState.text == nil ? .tertiary : .secondary)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 3)
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
            .helpHint("Reset all bands to a flat 10-band layout")
            Toggle("Start at Login", isOn: Binding(
                get: { startAtLogin },
                set: { on in
                    if on { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                    startAtLogin = SMAppService.mainApp.status == .enabled
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(
                    string: "https://github.com/sponsors/wabsto1")!)
            } label: {
                Image(systemName: "heart")
            }
            .buttonStyle(.borderless)
            .helpHint("ParaEQ is free — sponsor development if it's useful to you")
            Button {
                NSWorkspace.shared.open(URL(
                    string: "https://github.com/wabsto1/ParaEQ/blob/main/docs/USER-GUIDE.md")!)
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .helpHint("Open the user guide. Keyboard: ⌘Z undo, Tab select band, ↑↓←→ adjust, ⌘B bypass")
            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Window accessor
//
// Captures the NSWindow hosting a SwiftUI view, so the keyboard monitor can
// tell which EQView instance an event belongs to.

private struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onWindow(nsView?.window) }
    }
}

// MARK: - Band Row

struct BandRow: View {
    let index: Int
    @Binding var band: EQBand
    var isSelected = false
    @Binding var bandwidthOct: Bool
    var onChange: () -> Void
    var onSelect: () -> Void = {}

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Summary row — always visible
            Button {
                isExpanded.toggle()
                onSelect()
            } label: {
                HStack(spacing: 8) {
                    Toggle("", isOn: $band.enabled)
                        .labelsHidden()
                        .onChange(of: band.enabled) { _, _ in onChange() }
                        .helpHint("Enable or bypass this band")

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

                    Text(bandwidthOct ? "BW" : "Q")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .onTapGesture { bandwidthOct.toggle() }
                        .helpHint("Click to switch between Q and bandwidth in octaves")
                    Text(bandwidthOct
                         ? String(format: "%.2f", Bandwidth.octaves(fromQ: band.q))
                         : band.qLabel)
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
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            .helpHint("Click to \(isExpanded ? "collapse" : "expand") this band's controls; right-click to remove the band. Tab selects, arrows adjust")

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
                            Text(bandwidthOct ? "BW" : "Q")
                                .font(.caption)
                                .frame(width: 36, alignment: .leading)
                                .onTapGesture { bandwidthOct.toggle() }
                            Slider(
                                value: logBinding(
                                    value: $band.q,
                                    range: 0.1...30
                                ),
                                in: log10(0.1)...log10(30)
                            )
                            .onChange(of: band.q) { _, _ in onChange() }
                            Text(bandwidthOct
                                 ? Bandwidth.octaveLabel(forQ: band.q)
                                 : band.qLabel)
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
