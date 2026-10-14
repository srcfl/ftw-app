import FTWShared
import SwiftUI

/// What a chart draws, as a value: equal values draw the same picture, so
/// the surface redraws only when its data changes, never under a finger.
protocol ChartDrawing: Equatable {
    func draw(in g: inout GraphicsContext, size: CGSize)
}

/// Where the plot sits inside a chart's frame: room above for the scrub
/// tag, below for the time axis, and a gutter on the right for the mono
/// labels. The surface and the overlay take the same frame, so a finger
/// and a bar meet at the same x.
struct ChartFrame: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0

    func plot(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: top, width: max(0, size.width - trailing), height: max(0, size.height - top - bottom))
    }
}

/// One chart's picture: a single Canvas that never sees the scrub. The
/// finger has its own small overlay on top (`ScrubOverlay`), so a touch
/// redraws that and nothing here.
struct ChartSurface<Drawing: ChartDrawing>: View, Equatable {
    let drawing: Drawing

    nonisolated static func == (a: Self, b: Self) -> Bool { a.drawing == b.drawing }

    var body: some View {
        Canvas(rendersAsynchronously: false) { g, size in
            #if DEBUG
            ChartDraws.surface += 1
            #endif
            drawing.draw(in: &g, size: size)
        }
    }
}

#if DEBUG
/// How often the surfaces and the overlays drew, and what the overlays
/// cost, for the debug frame log. Main thread only.
@MainActor
enum ChartDraws {
    static var surface = 0
    static var overlay = 0
    /// Slot or span changes under a finger.
    static var changes = 0
    static var overlayMs = 0.0
    static var worstMs = 0.0

    /// The live trace's frames and what they cost.
    static var traces = 0
    static var traceMs = 0.0
    static var traceWorstMs = 0.0

    /// The flow's beams on Now: frames and what they cost.
    static var flows = 0
    static var flowMs = 0.0
    static var flowWorstMs = 0.0

    static func flow(_ d: Duration) {
        let ms = d / .milliseconds(1)
        flows += 1
        flowMs += ms
        flowWorstMs = max(flowWorstMs, ms)
    }

    static func trace(_ d: Duration) {
        let ms = d / .milliseconds(1)
        traces += 1
        traceMs += ms
        traceWorstMs = max(traceWorstMs, ms)
    }

    static func overlayDrew(_ d: Duration) {
        let ms = d / .milliseconds(1)
        overlay += 1
        overlayMs += ms
        worstMs = max(worstMs, ms)
    }

    static func take() -> (surface: Int, overlay: Int, changes: Int, overlayMs: Double, worstMs: Double, traces: Int, traceMs: Double, traceWorstMs: Double, flows: Int, flowMs: Double, flowWorstMs: Double) {
        defer {
            flows = 0
            flowMs = 0
            flowWorstMs = 0
            surface = 0
            overlay = 0
            changes = 0
            overlayMs = 0
            worstMs = 0
            traces = 0
            traceMs = 0
            traceWorstMs = 0
        }
        return (surface, overlay, changes, overlayMs, worstMs, traces, traceMs, traceWorstMs, flows, flowMs, flowWorstMs)
    }
}
#endif

/// The mono labels of a chart, resolved inside its Canvas so they never
/// reflow the layout.
enum ChartText {
    static func label(_ text: String, size: CGFloat = 10, weight: Font.Weight = .regular, color: Color = Theme.ink3) -> Text {
        Text(verbatim: text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .foregroundStyle(color)
    }
}
