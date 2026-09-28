import XCTest
@testable import ParaEQ

final class PresetManagerTests: XCTestCase {
    func testSavingExistingNameUpdatesInPlaceAndPersists() throws {
        let manager = PresetManager()
        let name = UUID().uuidString
        let otherName = UUID().uuidString
        defer {
            for preset in manager.customPresets where [name, otherName].contains(preset.name) {
                manager.delete(preset)
            }
        }
        manager.save(name: name, bands: [EQBand(gain: 2)], preamp: -2)
        let original = try XCTUnwrap(manager.customPresets.last)
        manager.save(name: otherName, bands: [EQBand(gain: -3)], preamp: nil)
        let before = manager.customPresets
        let updatedBands = [EQBand(frequency: 4000, gain: -5)]

        let saved = manager.save(name: name, bands: updatedBands, preamp: nil)

        XCTAssertEqual(manager.customPresets.count, before.count)
        XCTAssertEqual(manager.customPresets.map(\.id), before.map(\.id))
        let updated = try XCTUnwrap(manager.customPresets.first { $0.id == original.id })
        XCTAssertEqual(saved, updated)
        XCTAssertEqual(updated.bands, updatedBands)
        XCTAssertNil(updated.preamp)
        XCTAssertEqual(manager.customPresets.last, before.last)
        XCTAssertEqual(PresetManager().customPresets, manager.customPresets)
    }

    func testSavingBuiltInNameCreatesCustomPreset() throws {
        let manager = PresetManager()
        let builtIn = EQPreset.flat
        let originalPresets = manager.customPresets
        // Keep any existing user preset with this name intact.
        guard !originalPresets.contains(where: { $0.name == builtIn.name }) else {
            throw XCTSkip("A custom preset already uses this built-in name")
        }
        manager.save(name: builtIn.name, bands: [EQBand(gain: -4)], preamp: -1)
        let saved = try XCTUnwrap(manager.customPresets.last)
        defer { manager.delete(saved) }
        XCTAssertNotEqual(saved.id, builtIn.id)
        XCTAssertFalse(saved.isBuiltIn)
        XCTAssertEqual(EQPreset.flat, builtIn)
    }
}
