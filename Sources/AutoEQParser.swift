import Foundation

struct AutoEQResult {
    var preamp: Float?
    var bands: [EQBand]
    var originalCount: Int

    /// Normalize to exactly `count` bands: pad with zero-gain or truncate.
    func normalized(to count: Int) -> AutoEQResult {
        var result = self
        if bands.count > count {
            result.bands = Array(bands.prefix(count))
        } else if bands.count < count {
            let defaults = makeDefaultBands()
            var padded = bands
            while padded.count < count {
                padded.append(defaults[padded.count])
            }
            result.bands = padded
        }
        return result
    }
}

enum AutoEQParser {
    /// Parse EqualizerAPO ParametricEQ.txt format.
    static func parse(_ text: String) -> AutoEQResult {
        var preamp: Float?
        var bands: [EQBand] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Preamp line: "Preamp: -6.2 dB"
            if trimmed.lowercased().hasPrefix("preamp:") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let val = Float(parts[1]) {
                    preamp = val
                }
                continue
            }

            // Filter line: "Filter N: ON PK Fc 21 Hz Gain 6.5 dB Q 0.51"
            // Also handles: "Filter N: ON PK Fc 21 Hz Gain 6.5 dB BW Oct 0.83"
            guard trimmed.lowercased().hasPrefix("filter") else { continue }
            guard let band = parseFilterLine(trimmed) else { continue }
            bands.append(band)
        }

        return AutoEQResult(preamp: preamp, bands: bands, originalCount: bands.count)
    }

    private static func parseFilterLine(_ line: String) -> EQBand? {
        // Tokenize
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Find ON/OFF
        guard let onIdx = tokens.firstIndex(where: { $0.uppercased() == "ON" || $0.uppercased() == "OFF" }) else {
            return nil
        }
        let enabled = tokens[onIdx].uppercased() == "ON"

        // Filter type is next token after ON/OFF
        guard onIdx + 1 < tokens.count else { return nil }
        let typeStr = tokens[onIdx + 1].uppercased()
        let filterType = mapFilterType(typeStr)

        // Extract Fc, Gain, Q/BW
        var frequency: Float = 1000
        var gain: Float = 0
        var q: Float = 1.41

        for i in tokens.indices {
            let upper = tokens[i].uppercased()
            if upper == "FC", i + 1 < tokens.count, let f = Float(tokens[i + 1]) {
                frequency = f
            }
            if upper == "GAIN", i + 1 < tokens.count, let g = Float(tokens[i + 1]) {
                gain = g
            }
            if upper == "Q", i + 1 < tokens.count, let qVal = Float(tokens[i + 1]) {
                q = qVal
            }
            // BW Oct → convert bandwidth in octaves to Q
            if upper == "BW", i + 1 < tokens.count, tokens[i + 1].uppercased() == "OCT",
               i + 2 < tokens.count, let bw = Float(tokens[i + 2]) {
                // Q = sqrt(2^N) / (2^N - 1) where N = bandwidth in octaves
                let pow2n = powf(2.0, bw)
                q = sqrtf(pow2n) / (pow2n - 1.0)
            }
        }

        return EQBand(frequency: frequency, gain: gain, q: q, filterType: filterType, enabled: enabled)
    }

    private static func mapFilterType(_ code: String) -> FilterType {
        switch code {
        case "PK", "PEQ": return .parametric
        case "LSC", "LS", "LSQ": return .lowShelf
        case "HSC", "HS", "HSQ": return .highShelf
        case "LP", "LPQ": return .lowPass
        case "HP", "HPQ": return .highPass
        case "BP": return .bandPass
        case "NO": return .bandStop
        default: return .parametric
        }
    }
}
