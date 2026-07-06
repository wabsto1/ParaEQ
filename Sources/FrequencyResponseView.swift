import SwiftUI

struct FrequencyResponseView: View {
    @Binding var bands: [EQBand]
    /// Band highlighted for keyboard editing; set by clicks/drags here.
    @Binding var selectedBand: Int?
    /// Half-range of the gain axis (±6/12/18/24 dB).
    var dbSpan: Double = 24
    /// Live spectra in dB (SpectrumTap.floorDB…0), log-spaced 20 Hz–20 kHz;
    /// empty = hidden.
    var spectrumPre: [Float] = []
    var spectrumPost: [Float] = []
    /// Pop-out window: let the graph grow with the window.
    var flexibleHeight = false
    var onChange: () -> Void = {}

    @State private var draggedBand: Int?

    private let graphHeight: CGFloat = 130
    private let leftMargin: CGFloat = 28
    private let bottomMargin: CGFloat = 14
    private var dbRange: ClosedRange<Double> { -dbSpan...dbSpan }

    private var dbLines: [Double] {
        stride(from: -dbSpan, through: dbSpan, by: dbSpan / 4).map { $0 }
    }
    private let freqLines: [(Double, String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]

    var body: some View {
        GeometryReader { geo in
            let plotRect = CGRect(x: leftMargin, y: 0,
                                  width: geo.size.width - leftMargin,
                                  height: geo.size.height - bottomMargin)
            Canvas { context, size in
                drawGrid(context: context, plotRect: plotRect, fullSize: size)
                drawSpectrum(context: context, plotRect: plotRect,
                             values: spectrumPre, color: .cyan, fill: 0.06, line: 0.25)
                drawSpectrum(context: context, plotRect: plotRect,
                             values: spectrumPost, color: .orange, fill: 0.10, line: 0.40)
                drawBandCurves(context: context, plotRect: plotRect)
                drawCombinedCurve(context: context, plotRect: plotRect)
                drawBandDots(context: context, plotRect: plotRect)
            }
            .gesture(dragGesture(plotRect: plotRect))
        }
        .frame(minHeight: graphHeight,
               maxHeight: flexibleHeight ? .infinity : graphHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Live spectrum overlay (own dB scale: floorDB…0 → plot height)

    private func drawSpectrum(context: GraphicsContext, plotRect: CGRect,
                              values: [Float], color: Color,
                              fill: Double, line: Double) {
        guard values.count > 1 else { return }
        let floorDB = Double(SpectrumTap.floorDB)
        var path = Path()
        for (i, db) in values.enumerated() {
            let x = plotRect.minX + CGFloat(i) / CGFloat(values.count - 1) * plotRect.width
            let t = (min(max(Double(db), floorDB), 0) - floorDB) / -floorDB
            let y = plotRect.maxY - CGFloat(t) * plotRect.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        var fillPath = path
        fillPath.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        fillPath.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(color.opacity(fill)))
        context.stroke(path, with: .color(color.opacity(line)), lineWidth: 1)
    }

    // MARK: - Drag-to-edit (drag a band dot: x = frequency, y = gain)

    private func dragGesture(plotRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggedBand == nil {
                    draggedBand = nearestBand(to: value.startLocation, in: plotRect)
                    selectedBand = draggedBand
                }
                guard let i = draggedBand, bands.indices.contains(i) else { return }
                let freq = xToFreq(value.location.x, in: plotRect)
                bands[i].frequency = Float(min(max(freq, 20), 20000))
                if bands[i].filterType.usesGain {
                    let db = yToDb(value.location.y, in: plotRect)
                    bands[i].gain = Float((min(max(db, -24), 24) * 10).rounded() / 10)
                }
                onChange()
            }
            .onEnded { _ in draggedBand = nil }
    }

    private func nearestBand(to point: CGPoint, in plotRect: CGRect) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (i, band) in bands.enumerated() where band.enabled {
            let x = freqToX(Double(band.frequency), in: plotRect)
            let y = dbToY(combinedDB(at: Double(band.frequency)), in: plotRect)
            let d = hypot(point.x - x, point.y - y)
            if d < 14, d < (best?.dist ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    private func combinedDB(at freq: Double) -> Double {
        bands.reduce(0.0) { $0 + FrequencyResponse.magnitudeDB(for: $1, atFrequency: freq) }
    }

    private func xToFreq(_ x: CGFloat, in rect: CGRect) -> Double {
        let t = Double((x - rect.minX) / rect.width)
        return pow(10, log10(20.0) + t * (log10(20000.0) - log10(20.0)))
    }

    private func yToDb(_ y: CGFloat, in rect: CGRect) -> Double {
        let normalized = Double((rect.maxY - y) / rect.height)
        return dbRange.lowerBound + normalized * (dbRange.upperBound - dbRange.lowerBound)
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

        for (i, band) in bands.enumerated() {
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
            if i == selectedBand {
                let ring = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
                context.stroke(ring, with: .color(.accentColor), lineWidth: 1.5)
            }
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
