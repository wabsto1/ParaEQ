import SwiftUI

struct FrequencyResponseView: View {
    var bands: [EQBand]

    private let graphHeight: CGFloat = 130
    private let leftMargin: CGFloat = 28
    private let bottomMargin: CGFloat = 14
    private let dbRange: ClosedRange<Double> = -24...24

    private let dbLines: [Double] = [-24, -18, -12, -6, 0, 6, 12, 18, 24]
    private let freqLines: [(Double, String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]

    var body: some View {
        Canvas { context, size in
            let plotW = size.width - leftMargin
            let plotH = size.height - bottomMargin
            let plotRect = CGRect(x: leftMargin, y: 0, width: plotW, height: plotH)

            drawGrid(context: context, plotRect: plotRect, fullSize: size)
            drawBandCurves(context: context, plotRect: plotRect)
            drawCombinedCurve(context: context, plotRect: plotRect)
            drawBandDots(context: context, plotRect: plotRect)
        }
        .frame(height: graphHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Grid

    private func drawGrid(context: GraphicsContext, plotRect: CGRect, fullSize: CGSize) {
        let gridColor = Color.secondary.opacity(0.15)

        // Horizontal dB lines
        for db in dbLines {
            let y = dbToY(db, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: db == 0 ? 0.8 : 0.3)

            // dB label
            let text = Text(db == 0 ? "0" : String(format: "%+.0f", db))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: leftMargin - 3, y: y),
                anchor: .trailing
            )
        }

        // Vertical frequency lines
        for (freq, label) in freqLines {
            let x = freqToX(freq, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.3)

            // Frequency label
            let text = Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: x, y: fullSize.height - 1),
                anchor: .bottom
            )
        }
    }

    // MARK: - Individual band curves

    private func drawBandCurves(context: GraphicsContext, plotRect: CGRect) {
        let pointCount = max(2, Int(plotRect.width))
        for band in bands {
            guard band.enabled else { continue }
            let curve = FrequencyResponse.bandCurve(for: band, pointCount: pointCount)
            let path = curvePath(curve, in: plotRect)
            context.stroke(path, with: .color(.accentColor.opacity(0.25)), lineWidth: 1)
        }
    }

    // MARK: - Combined curve

    private func drawCombinedCurve(context: GraphicsContext, plotRect: CGRect) {
        let pointCount = max(2, Int(plotRect.width))
        let curve = FrequencyResponse.responseCurve(for: bands, pointCount: pointCount)
        let strokePath = curvePath(curve, in: plotRect)

        // Fill to 0dB line
        let zeroY = dbToY(0, in: plotRect)
        var fillPath = strokePath
        if pointCount > 0 {
            fillPath.addLine(to: CGPoint(x: plotRect.maxX, y: zeroY))
            fillPath.addLine(to: CGPoint(x: plotRect.minX, y: zeroY))
            fillPath.closeSubpath()
        }
        context.fill(fillPath, with: .color(.accentColor.opacity(0.1)))
        context.stroke(strokePath, with: .color(.accentColor), lineWidth: 2)
    }

    // MARK: - Band dots

    private func drawBandDots(context: GraphicsContext, plotRect: CGRect) {
        let pointCount = max(2, Int(plotRect.width))
        let combinedCurve = FrequencyResponse.responseCurve(for: bands, pointCount: pointCount)
        let freqs = FrequencyResponse.logFrequencies(count: pointCount)

        for band in bands {
            guard band.enabled else { continue }
            let f = Double(band.frequency)
            let x = freqToX(f, in: plotRect)

            // Find the combined dB at this band's frequency by interpolation
            let combinedDB: Double = {
                guard let idx = freqs.firstIndex(where: { $0 >= f }) else {
                    return combinedCurve.last ?? 0
                }
                if idx == 0 { return combinedCurve[0] }
                let f0 = freqs[idx - 1], f1 = freqs[idx]
                let t = (f - f0) / (f1 - f0)
                return combinedCurve[idx - 1] + t * (combinedCurve[idx] - combinedCurve[idx - 1])
            }()

            let y = dbToY(combinedDB, in: plotRect)
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(.accentColor))
        }
    }

    // MARK: - Helpers

    private func curvePath(_ curve: [Double], in rect: CGRect) -> Path {
        var path = Path()
        for (i, db) in curve.enumerated() {
            let x = rect.minX + CGFloat(i) / CGFloat(max(1, curve.count - 1)) * rect.width
            let y = dbToY(db, in: rect)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func dbToY(_ db: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(db, dbRange.lowerBound), dbRange.upperBound)
        let normalized = (clamped - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)
        return rect.maxY - CGFloat(normalized) * rect.height
    }

    private func freqToX(_ freq: Double, in rect: CGRect) -> CGFloat {
        let logMin = log10(20.0)
        let logMax = log10(20000.0)
        let t = (log10(max(freq, 20)) - logMin) / (logMax - logMin)
        return rect.minX + CGFloat(t) * rect.width
    }
}
