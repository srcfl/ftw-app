import FTWKit
import SwiftUI

/// How a chart's points move when its data changes: each point that
/// changed springs from where it was drawn to its new value, a few
/// milliseconds after the point before it, so a curve grows into shape
/// rather than jumping. An estimate the data replaces, or a hole the box
/// confirms, fades as the line settles. Under Reduce Motion the new data
/// shows at once and only the fade remains.
///
/// The points are computed once per change of data; the motion only
/// interpolates between two lists it already has.
enum ChartMotion {
    /// The spring Fredrik's brief names: response 0.55 s, damping 0.72.
    static let response = 0.55
    static let damping = 0.72
    /// Between one changed point and the next.
    static let stagger = 0.008
    /// The whole stagger never takes longer than this, however many points.
    static let staggerCap = 0.35
    /// How long a fading estimate takes to go.
    static let fade = 0.3

    /// A damped spring's step from 0 to 1 at `t` seconds, as
    /// `.spring(response:dampingFraction:)` moves a value. It overshoots a
    /// little and settles.
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = damping
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return 1 - decay * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
    }

    /// When a spring has settled to within a hair of its value.
    static var settle: Double { response * 2 }
}

/// One change of a chart's points, followed while it moves.
struct ChartChange: Equatable {
    /// Where each changed point was drawn when the change began, by id.
    var from: [Double: Double] = [:]
    /// Each changed point's place in the stagger, by id.
    var order: [Double: Int] = [:]
    /// Estimates the change took away, drawn fading.
    var fading: [HistoryPlot.Point] = []
    var began: Date = .distantPast
    var stagger: Double = ChartMotion.stagger

    /// How long this change moves for.
    var duration: Double { ChartMotion.settle + Double(order.count) * stagger }

    /// The points as drawn at `date`.
    func drawn(_ points: [HistoryPlot.Point], at date: Date) -> [HistoryPlot.Point] {
        guard !order.isEmpty else { return points }
        let elapsed = date.timeIntervalSince(began)
        return points.map { p in
            guard let i = order[p.id], let start = from[p.id] else { return p }
            let f = ChartMotion.spring(elapsed - Double(i) * stagger)
            return HistoryPlot.Point(t: p.t, v: start + (p.v - start) * f, kind: p.kind, run: p.run, id: p.id)
        }
    }

    /// How much of the fading estimates is left at `date`.
    func fadeLeft(at date: Date) -> Double {
        max(0, 1 - date.timeIntervalSince(began) / ChartMotion.fade)
    }

    /// The change from what was drawn to `new`. A point that is new springs
    /// from its neighbour on the left, or from zero on a chart's first data,
    /// so it grows in rather than appearing.
    static func between(_ old: [HistoryPlot.Point], drawn: [HistoryPlot.Point], _ new: [HistoryPlot.Point], at date: Date, still: Bool) -> ChartChange {
        var change = ChartChange(began: date)
        let before = Dictionary(drawn.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.filter { $0.kind == .estimate }.map(\.id))
        change.fading = old.filter { $0.kind == .estimate && !newIDs.contains($0.id) }
        guard !still else { return change }
        var order = 0
        var left: Double = 0
        for p in new {
            if let was = before[p.id] {
                if abs(was.v - p.v) > 0.5 || oldByID[p.id]?.kind != p.kind {
                    change.from[p.id] = was.v
                    change.order[p.id] = order
                    order += 1
                }
            } else {
                change.from[p.id] = old.isEmpty ? 0 : left
                change.order[p.id] = order
                order += 1
            }
            left = p.v
        }
        if order > 0 { change.stagger = min(ChartMotion.stagger, ChartMotion.staggerCap / Double(order)) }
        return change
    }
}

/// Holds a chart's points and moves between them: the chart draws what
/// `content` is handed, at the display's rate while a change moves and not
/// at all otherwise. What the chart already has when it appears starts
/// settled, so a view opened again never grows from zero; only what
/// changes while it is on screen moves.
struct MovingPoints<Content: View>: View {
    let points: [HistoryPlot.Point]
    @ViewBuilder let content: (_ drawn: [HistoryPlot.Point], _ fading: [HistoryPlot.Point], _ fadeLeft: Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: [HistoryPlot.Point] = []
    @State private var change = ChartChange()
    @State private var moving = false

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            let now = moving ? context.date : .distantFuture
            content(change.drawn(shown, at: now), change.fading, change.fading.isEmpty ? 0 : change.fadeLeft(at: now))
        }
        .onAppear { settle(points) }
        .onChange(of: points) { _, new in begin(new) }
    }

    private func settle(_ new: [HistoryPlot.Point]) {
        shown = new
        change = ChartChange()
        moving = false
    }

    private func begin(_ new: [HistoryPlot.Point]) {
        let now = Date()
        // Interrupted mid-move: start from where the points are drawn now.
        let drawn = change.drawn(shown, at: now)
        change = ChartChange.between(shown, drawn: drawn, new, at: now, still: reduceMotion)
        shown = new
        let length = max(change.order.isEmpty ? 0 : change.duration, change.fading.isEmpty ? 0 : ChartMotion.fade)
        guard length > 0 else {
            moving = false
            return
        }
        moving = true
        let began = change.began
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(length + 0.05))
            if change.began == began { moving = false }
        }
    }
}
