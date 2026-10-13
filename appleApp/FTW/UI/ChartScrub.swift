import Charts
import FTWKit
import SwiftUI

/// The line under a chart: its readout while the finger is down, else its
/// own sentence. The swap is instant, as the finger is, and nothing below
/// them moves.
struct ReadoutLine: View {
    let readout: ChartReadout?
    let otherwise: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The sentence keeps its room, so a shorter readout does not
            // pull the card up.
            Text(otherwise)
                .opacity(readout == nil ? 1 : 0)
            if let readout {
                (Text(readout.when).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.fg)
                    + Text(verbatim: "  ")
                    + Text(readout.what).foregroundStyle(Theme.fg))
                    .accessibilityIdentifier("chart.readout")
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.fgDim)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

/// The finger on a chart: one slot, or two fingers' range. A light tick
/// per slot (never more than about 25 a second) and a firmer one at a
/// landmark: now, the edges of the cheapest hours, the day's high and low,
/// the car's goal. Nothing on a data update.
struct ChartScrub: ViewModifier {
    @Binding var selected: Date?
    @Binding var range: ClosedRange<Date>?
    /// The slot a moment falls in, so a tick marks a step, not a pixel.
    let slot: (Date) -> Double?
    /// Whether a slot is a landmark.
    let landmark: (Double) -> Bool
    @State private var ticks = 0
    @State private var bumps = 0
    @State private var lastSlot: Double?
    @State private var lastTick = Date.distantPast

    func body(content: Content) -> some View {
        content
            .chartXSelection(value: $selected.animation(Theme.spring))
            .chartXSelection(range: $range.animation(Theme.spring))
            .onChange(of: selected) { _, date in
                guard let date, let s = slot(date) else {
                    lastSlot = nil
                    return
                }
                guard s != lastSlot else { return }
                lastSlot = s
                if landmark(s) {
                    bumps += 1
                } else if Date().timeIntervalSince(lastTick) >= 0.04 {
                    lastTick = Date()
                    ticks += 1
                }
            }
            .sensoryFeedback(.selection, trigger: ticks)
            .sensoryFeedback(.impact(weight: .light), trigger: bumps)
    }
}

extension View {
    func chartScrub(selected: Binding<Date?>, range: Binding<ClosedRange<Date>?>, slot: @escaping (Date) -> Double?, landmark: @escaping (Double) -> Bool = { _ in false }) -> some View {
        modifier(ChartScrub(selected: selected, range: range, slot: slot, landmark: landmark))
    }
}

/// The marks for the place under the finger: a thin rule, and a dot on the
/// line where there is one.
@ChartContentBuilder
func scrubMarks(_ date: Date?, value: Double?, color: Color) -> some ChartContent {
    if let date {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(Theme.fgDim.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1))
        if let value {
            PointMark(x: .value("Selected", date), y: .value("Power", value))
                .foregroundStyle(color)
                .symbolSize(60)
        }
    }
}

/// History as VoiceOver reads it: an hour a step, with the power and which
/// way it flowed.
struct HistoryDescriptor: AXChartDescriptorRepresentable {
    let node: EnergyNode
    let samples: [HistorySample]
    let fromMs: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let hour: Double = 3_600_000
        var hours: [(t: Double, v: Double)] = []
        let byHour = Dictionary(grouping: samples.filter { $0.watts != nil }) { ($0.startMs / hour).rounded(.down) }
        for key in byHour.keys.sorted() {
            let values = byHour[key]!.compactMap(\.watts)
            hours.append((max(fromMs, key * hour), values.reduce(0, +) / Double(values.count)))
        }
        let lo = min(0, hours.map(\.v).min() ?? 0), hi = max(0, hours.map(\.v).max() ?? 0)
        let end = samples.last.map { $0.startMs + $0.stepMs } ?? fromMs
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: fromMs...max(fromMs + 1, end), gridlinePositions: []) { Readouts.clock($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Power"), range: lo...max(lo + 1, hi), gridlinePositions: []) { AppWords.power(abs($0)) }
        let series = AXDataSeriesDescriptor(name: node.title, isContinuous: true, dataPoints: hours.map {
            AXDataPoint(x: $0.t, y: $0.v, additionalValues: [], label: Readouts.word(node, $0.v))
        })
        return AXChartDescriptor(title: node.title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
