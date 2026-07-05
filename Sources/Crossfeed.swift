import Foundation

// MARK: - Channel processing modes

enum ChannelMode: String, Codable, CaseIterable, Identifiable {
    case linked      // one band set, both channels
    case stereo      // independent Left / Right band sets
    case midSide     // band sets applied to Mid / Side

    var id: String { rawValue }
    var name: String {
        switch self {
        case .linked: "Stereo"
        case .stereo: "L / R"
        case .midSide: "Mid / Side"
        }
    }
    var channelNames: (String, String) {
        switch self {
        case .linked: ("", "")
        case .stereo: ("Left", "Right")
        case .midSide: ("Mid", "Side")
        }
    }
}

enum CrossfeedMode: String, Codable, CaseIterable, Identifiable {
    case off
    case chuMoy
    case janMeier

    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: "Off"
        case .chuMoy: "Chu Moy"
        case .janMeier: "Jan Meier"
        }
    }
}

// MARK: - Single biquad with state (for the crossfeed low-pass legs)

struct StatefulBiquad {
    var c: BiquadCoefficients = .unity
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = Float(c.b0) * x + Float(c.b1) * x1 + Float(c.b2) * x2
              - Float(c.a1) * y1 - Float(c.a2) * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

// MARK: - Headphone crossfeed
//
// Classic analog-crossfeed emulation (after the Chu Moy / Jan Meier designs
// as popularized by Equalizer APO / Peace recipes): each ear receives the
// opposite channel low-passed (head shadow) and attenuated, with the direct
// level trimmed to keep overall loudness. Realtime-safe, in-place.

final class Crossfeed {
    private var lpLtoR = StatefulBiquad()
    private var lpRtoL = StatefulBiquad()
    private let crossGain: Float
    private let directGain: Float

    init(mode: CrossfeedMode, sampleRate: Double) {
        // (cutoff Hz, crossfeed level dB) per design
        let (fc, crossDB): (Float, Float) = switch mode {
        case .chuMoy:   (700, -9.5)
        case .janMeier: (650, -9.5)
        case .off:      (700, -9.5) // unused
        }
        let lp = BiquadCoefficients.compute(
            for: EQBand(frequency: fc, gain: 0, q: 0.7071,
                        filterType: .lowPass, enabled: true),
            sampleRate: sampleRate)
        lpLtoR.c = lp
        lpRtoL.c = lp
        crossGain = powf(10, crossDB / 20)
        // Keep summed energy roughly constant
        directGain = 1.0 / (1.0 + crossGain * 0.5)
    }

    /// Process planar stereo in place.
    func process(l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>,
                 frames: Int) {
        for i in 0..<frames {
            let inL = l[i]
            let inR = r[i]
            let bleedL = lpRtoL.process(inR) * crossGain
            let bleedR = lpLtoR.process(inL) * crossGain
            l[i] = inL * directGain + bleedL
            r[i] = inR * directGain + bleedR
        }
    }
}
