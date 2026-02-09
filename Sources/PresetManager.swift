import Foundation
import Observation

@Observable
final class PresetManager {
    private(set) var customPresets: [EQPreset] = []

    var allPresets: [EQPreset] {
        EQPreset.builtIn + customPresets
    }

    init() {
        loadPresets()
    }

    func save(name: String, bands: [EQBand], preamp: Float?) {
        let preset = EQPreset(
            id: UUID().uuidString,
            name: name,
            bands: bands,
            preamp: preamp
        )
        customPresets.append(preset)
        persistPresets()
    }

    func delete(_ preset: EQPreset) {
        guard !preset.isBuiltIn else { return }
        customPresets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    func addImported(_ preset: EQPreset) {
        customPresets.append(preset)
        persistPresets()
    }

    // MARK: - Persistence

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "paraeq.customPresets")
        }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: "paraeq.customPresets"),
              let saved = try? JSONDecoder().decode([EQPreset].self, from: data)
        else { return }
        customPresets = saved
    }
}
