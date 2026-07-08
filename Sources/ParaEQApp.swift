import SwiftUI

@main
struct ParaEQApp: App {
    @State private var engine: AudioEngine
    @State private var appMixer: AppMixer

    init() {
        // Native tooltips default to a ~3 s hover delay; make them snappy.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        let engine = AudioEngine()
        _engine = State(initialValue: engine)
        _appMixer = State(initialValue: AppMixer(
            engine: engine, directory: AppAudioDirectory()))
    }

    var body: some Scene {
        MenuBarExtra("ParaEQ", systemImage: "slider.vertical.3") {
            EQView(engine: engine, appMixer: appMixer)
        }
        .menuBarExtraStyle(.window)

        // Pop-out: the same UI in a resizable window (spectrum watching,
        // side-by-side use). Shares the one engine with the panel.
        Window("ParaEQ", id: "popout") {
            EQView(engine: engine, appMixer: appMixer, inWindow: true)
        }
        .defaultSize(width: 520, height: 880)

        // Balance calibration lives in its own window (not a panel sheet):
        // MenuBarExtra panels dismiss on interaction, and the user's hands
        // are holding headphones during the measurement anyway.
        Window("Balance Calibration", id: "balance-calibration") {
            BalanceWizardView(engine: engine)
        }
        .windowResizability(.contentSize)
    }
}
