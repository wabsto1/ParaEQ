import SwiftUI

/// Reads the engine's peak levels in its own body so the 30 fps meter ticks
/// invalidate only this small view, never the whole panel.
struct LevelMeterView: View {
    var engine: AudioEngine

    var body: some View {
        VStack(spacing: 2) {
            meterBar(level: CGFloat(engine.peakL))
            meterBar(level: CGFloat(engine.peakR))
        }
    }

    private func meterBar(level: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.08))

                // Fill
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(meterGradient)
                    .frame(width: max(0, geo.size.width * min(level, 1.0)))
            }
        }
        .frame(height: 4)
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
