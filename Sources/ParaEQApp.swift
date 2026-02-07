import SwiftUI

@main
struct ParaEQApp: App {
    @State private var engine = AudioEngine()

    var body: some Scene {
        MenuBarExtra("ParaEQ", systemImage: "slider.vertical.3") {
            EQView(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}
