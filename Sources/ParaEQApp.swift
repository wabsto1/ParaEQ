import SwiftUI

@main
struct ParaEQApp: App {
    @State private var engine = AudioEngine()

    init() {
        // Native tooltips default to a ~3 s hover delay; make them snappy.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    var body: some Scene {
        MenuBarExtra("ParaEQ", systemImage: "slider.vertical.3") {
            EQView(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}
