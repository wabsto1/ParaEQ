import AVFoundation

// MARK: - Filter Type

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case parametric
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case bandStop

    var id: String { rawValue }

    var name: String {
        switch self {
        case .parametric: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .bandPass: "Band Pass"
        case .bandStop: "Notch"
        }
    }

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        case .lowPass: .lowPass
        case .highPass: .highPass
        case .bandPass: .bandPass
        case .bandStop: .bandStop
        }
    }
}

// MARK: - EQ Band

struct EQBand: Codable, Equatable {
    var frequency: Float = 1000  // 20–20000 Hz
    var gain: Float = 0          // -24 to +24 dB
    var q: Float = 1.41          // 0.1 to 30
    var filterType: FilterType = .parametric
    var enabled: Bool = true

    /// Convert Q to bandwidth in octaves for AVAudioUnitEQ
    var bandwidth: Float {
        let q = max(0.01, Double(self.q))
        return Float(2.0 * asinh(1.0 / (2.0 * q)) / log(2.0))
    }

    var frequencyLabel: String {
        if frequency >= 1000 {
            let khz = frequency / 1000
            return khz == floor(khz)
                ? "\(Int(khz))k" : String(format: "%.1fk", khz)
        }
        return "\(Int(frequency))"
    }

    var gainLabel: String { String(format: "%+.1f", gain) }
    var qLabel: String { String(format: "%.2f", q) }
}

// MARK: - Preset

struct EQPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var bands: [EQBand]

    static let builtIn: [EQPreset] = [flat, bassBoost, vocalClarity, trebleBoost, t5pHarman, t5pBassBoost]

    static let flat = EQPreset(
        id: "flat", name: "Flat",
        bands: makeDefaultBands()
    )

    static let bassBoost: EQPreset = {
        var bands = makeDefaultBands()
        bands[0].gain = 6.0
        bands[1].gain = 4.5
        bands[2].gain = 2.0
        return EQPreset(id: "bass-boost", name: "Bass Boost", bands: bands)
    }()

    static let vocalClarity: EQPreset = {
        var bands = makeDefaultBands()
        bands[3].gain = 2.0   // 250 Hz slight cut? no, boost mids
        bands[4].gain = 3.0   // 500 Hz
        bands[5].gain = 3.5   // 1 kHz
        bands[6].gain = 2.0   // 2 kHz
        bands[0].gain = -2.0  // reduce bass
        bands[1].gain = -1.5
        return EQPreset(id: "vocal-clarity", name: "Vocal Clarity", bands: bands)
    }()

    static let trebleBoost: EQPreset = {
        var bands = makeDefaultBands()
        bands[7].gain = 3.0   // 4 kHz
        bands[8].gain = 4.5   // 8 kHz
        bands[9].gain = 5.0   // 16 kHz
        return EQPreset(id: "treble-boost", name: "Treble Boost", bands: bands)
    }()

    // Beyerdynamic T5p 2nd Gen — corrective EQ toward Harman target
    static let t5pHarman: EQPreset = {
        var bands = makeDefaultBands()
        bands[0].gain = -3.0; bands[0].q = 0.71   // 31 Hz low shelf: tame sub-bass rise
        bands[1].gain = -1.0; bands[1].q = 1.00   // 63 Hz: bass correction
        // 125, 250, 500 Hz: leave flat
        bands[5].gain = 0.5;  bands[5].q = 1.00   // 1 kHz: slight body
        bands[6].gain = -1.5                        // 2 kHz: ease into presence cut
        bands[7].frequency = 3200; bands[7].gain = -5.0; bands[7].q = 2.00  // presence peak correction
        bands[8].gain = -3.5; bands[8].q = 2.50   // 8 kHz: treble peak correction
        bands[9].gain = -1.0; bands[9].q = 0.71   // 16 kHz high shelf: slight air reduction
        return EQPreset(id: "t5p-harman", name: "T5p 2nd Harman", bands: bands)
    }()

    // Beyerdynamic T5p 2nd Gen — bass boost with upper-range correction
    static let t5pBassBoost: EQPreset = {
        var bands = makeDefaultBands()
        bands[0].gain = 4.0;  bands[0].q = 0.71   // 31 Hz low shelf: sub-bass boost
        bands[1].gain = 3.0;  bands[1].q = 1.00   // 63 Hz: mid-bass boost
        bands[2].gain = 2.0;  bands[2].q = 1.00   // 125 Hz: upper bass warmth
        bands[3].gain = 1.0;  bands[3].q = 1.00   // 250 Hz: warmth
        // 500, 1000 Hz: leave flat
        bands[6].gain = -1.5                        // 2 kHz: ease into presence cut
        bands[7].frequency = 3200; bands[7].gain = -5.0; bands[7].q = 2.00  // presence peak correction
        bands[8].gain = -3.0; bands[8].q = 2.50   // 8 kHz: treble peak correction
        bands[9].gain = -1.0; bands[9].q = 0.71   // 16 kHz high shelf: slight air reduction
        return EQPreset(id: "t5p-bass", name: "T5p 2nd Bass", bands: bands)
    }()
}

func makeDefaultBands() -> [EQBand] {
    let freqs: [Float] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    return freqs.enumerated().map { i, freq in
        EQBand(
            frequency: freq,
            gain: 0,
            q: 1.41,
            filterType: i == 0 ? .lowShelf : (i == freqs.count - 1 ? .highShelf : .parametric),
            enabled: true
        )
    }
}
