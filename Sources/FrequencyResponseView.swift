import SwiftUI

/// The EQ graph, layered as three canvases so the 30 fps spectrum overlay
/// never forces the expensive band-curve math to recompute:
///   grid (dbSpan/size only) → spectrum (cheap, 30 fps) → curves (band edits only).
struct FrequencyResponseView: View {
    @Binding var bands: [EQBand]
    /// Band highlighted for keyboard editing; set by clicks/drags here.
    @Binding var selectedBand: Int?
    /// Half-range of the gain axis (±6/12/18/24 dB).
    var dbSpan: Double = 24
    /// Engine whose live spectrum the overlay shows; only SpectrumCanvas's
    /// body reads the arrays, so 30 fps ticks re-render just that layer.
    var engine: AudioEngine? = nil
    /// Pop-out window: let the graph grow with the window.
    var flexibleHeight = false
    var onChange: () -> Void = {}

    @State private var draggedBand: Int?

    private let graphHeight: CGFloat = 130
    private let leftMargin: CGFloat = 28
    private let bottomMargin: CGFloat = 14
    private var dbRange: ClosedRange<Double> { -dbSpan...dbSpan }

    var body: some View {
        GeometryReader { geo in
            let plotRect = CGRect(x: leftMargin, y: 0,
                                  width: geo.size.width - leftMargin,
                                  height: geo.size.height - bottomMargin)
            ZStack {
                GridCanvas(dbSpan: dbSpan, plotRect: plotRect, leftMargin: leftMargin)
                if let engine {
                    SpectrumCanvas(engine: engine, plotRect: plotRect)
                }
                CurvesCanvas(bands: bands, selectedBand: selectedBand,
                             dbSpan: dbSpan, plotRect: plotRect)
                    .equatable()
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(plotRect: plotRect))
        }
        .frame(minHeight: graphHeight,
               maxHeight: flexibleHeight ? .infinity : graphHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
            let x = graphFreqToX(Double(band.frequency), in: plotRect)
            let y = graphDBToY(combinedDB(at: Double(band.frequency)),
                               dbSpan: dbSpan, in: plotRect)
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
}

// MARK: - Shared coordinate helpers

private func graphDBToY(_ db: Double, dbSpan: Double, in rect: CGRect) -> CGFloat {
    let clamped = min(max(db, -dbSpan), dbSpan)
    let normalized = (clamped + dbSpan) / (2 * dbSpan)
    return rect.maxY - CGFloat(normalized) * rect.height
}

private func graphFreqToX(_ freq: Double, in rect: CGRect) -> CGFloat {
    let logMin = log10(20.0)
    let logMax = log10(20000.0)
    let t = (log10(max(freq, 20)) - logMin) / (logMax - logMin)
    return rect.minX + CGFloat(t) * rect.width
}

// MARK: - Grid layer (redraws only when dbSpan or layout changes)

private struct GridCanvas: View {
    let dbSpan: Double
    let plotRect: CGRect
    let leftMargin: CGFloat

    private static let freqLines: [(Double, String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]

    var body: some View {
        Canvas { context, size in
            let gridColor = Color.secondary.opacity(0.15)

            // Horizontal dB lines
            for db in stride(from: -dbSpan, through: dbSpan, by: dbSpan / 4) {
                let y = graphDBToY(db, dbSpan: dbSpan, in: plotRect)
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
            for (freq, label) in Self.freqLines {
                let x = graphFreqToX(freq, in: plotRect)
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
                    at: CGPoint(x: x, y: size.height - 1),
                    anchor: .bottom
                )
            }
        }
    }
}

// MARK: - Live spectrum layer (redraws at 30 fps; two ~120-point paths, cheap)

private struct SpectrumCanvas: View {
    let engine: AudioEngine
    let plotRect: CGRect

    var body: some View {
        // Read the spectra here (not in a parent) so only this canvas
        // re-renders on each meter tick.
        let pre = engine.spectrumPre
        let post = engine.spectrumPost
        Canvas { context, _ in
            draw(context: context, values: pre, color: .cyan, fill: 0.06, line: 0.25)
            draw(context: context, values: post, color: .orange, fill: 0.10, line: 0.40)
        }
    }

    /// Own dB scale: floorDB…0 → plot height.
    private func draw(context: GraphicsContext, values: [Float], color: Color,
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
}

// MARK: - Curve layer (biquad-cascade math; redraws only on band/selection/span
// changes — Equatable so 30 fps spectrum ticks skip it entirely)

private struct CurvesCanvas: View, Equatable {
    let bands: [EQBand]
    let selectedBand: Int?
    let dbSpan: Double
    let plotRect: CGRect

    var body: some View {
        Canvas { context, _ in
            let pointCount = max(2, Int(plotRect.width))
            let combined = FrequencyResponse.responseCurve(for: bands, pointCount: pointCount)
            drawBandCurves(context: context, pointCount: pointCount)
            drawCombinedCurve(context: context, combined: combined)
            drawBandDots(context: context, combined: combined, pointCount: pointCount)
        }
    }

    private func drawBandCurves(context: GraphicsContext, pointCount: Int) {
        for band in bands {
            guard band.enabled else { continue }
            let curve = FrequencyResponse.bandCurve(for: band, pointCount: pointCount)
            let path = curvePath(curve)
            context.stroke(path, with: .color(.accentColor.opacity(0.25)), lineWidth: 1)
        }
    }

    private func drawCombinedCurve(context: GraphicsContext, combined: [Double]) {
        let strokePath = curvePath(combined)

        // Fill to 0dB line
        let zeroY = graphDBToY(0, dbSpan: dbSpan, in: plotRect)
        var fillPath = strokePath
        if !combined.isEmpty {
            fillPath.addLine(to: CGPoint(x: plotRect.maxX, y: zeroY))
            fillPath.addLine(to: CGPoint(x: plotRect.minX, y: zeroY))
            fillPath.closeSubpath()
        }
        context.fill(fillPath, with: .color(.accentColor.opacity(0.1)))
        context.stroke(strokePath, with: .color(.accentColor), lineWidth: 2)
    }

    private func drawBandDots(context: GraphicsContext, combined: [Double], pointCount: Int) {
        let freqs = FrequencyResponse.logFrequencies(count: pointCount)

        for (i, band) in bands.enumerated() {
            guard band.enabled else { continue }
            let f = Double(band.frequency)
            let x = graphFreqToX(f, in: plotRect)

            // Find the combined dB at this band's frequency by interpolation
            let combinedDB: Double = {
                guard let idx = freqs.firstIndex(where: { $0 >= f }) else {
                    return combined.last ?? 0
                }
                if idx == 0 { return combined[0] }
                let f0 = freqs[idx - 1], f1 = freqs[idx]
                let t = (f - f0) / (f1 - f0)
                return combined[idx - 1] + t * (combined[idx] - combined[idx - 1])
            }()

            let y = graphDBToY(combinedDB, dbSpan: dbSpan, in: plotRect)
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(.accentColor))
            if i == selectedBand {
                let ring = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
                context.stroke(ring, with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }

    private func curvePath(_ curve: [Double]) -> Path {
        var path = Path()
        for (i, db) in curve.enumerated() {
            let x = plotRect.minX + CGFloat(i) / CGFloat(max(1, curve.count - 1)) * plotRect.width
            let y = graphDBToY(db, dbSpan: dbSpan, in: plotRect)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
