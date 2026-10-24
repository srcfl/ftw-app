import FTWKit
import SwiftUI

// MARK: - Which series a chart shows

/// The series a node's history shows, per chart kind, kept per viewer.
/// The node's own series first; at least one always stays.
enum SeriesChoice {
    static func key(_ node: EnergyNode) -> String { "ftw.chart.series.\(node.rawValue)" }

    static func load(_ node: EnergyNode) -> [EnergyNode] {
        SeriesPick.read(UserDefaults.standard.string(forKey: key(node)), own: node)
    }

    static func save(_ series: [EnergyNode], for node: EnergyNode) {
        UserDefaults.standard.set(series.map(\.rawValue).joined(separator: ","), forKey: key(node))
    }
}

/// Quiet chips for the series a history can show: on, a series speaks in
/// its colour with a small dot; off, it is ink. A tap adds or takes away a
/// series, and the last one stays.
struct SeriesChips: View {
    let own: EnergyNode
    let available: [EnergyNode]
    @Binding var chosen: [EnergyNode]
    @State private var taps = 0
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 6) {
            ForEach(available, id: \.self) { node in
                let on = chosen.contains(node)
                Button {
                    let next = SeriesPick.toggled(chosen, node, own: own)
                    guard next != chosen else { return }
                    withAnimation(Theme.spring) { chosen = next }
                    SeriesChoice.save(next, for: own)
                    taps += 1
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(on ? NodeChartLook.color(node) : Color.clear)
                            .strokeBorder(on ? Color.clear : Theme.ink3, lineWidth: 1)
                            .frame(width: 6, height: 6)
                        Text(node.caps)
                            .font(.system(size: size, weight: .medium, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(on ? NodeChartLook.color(node) : Theme.ink3)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("chart.series.\(node.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .sensoryFeedback(.selection, trigger: taps)
    }
}

/// One colour pair per node, for every chart of it.
enum NodeChartLook {
    static func color(_ node: EnergyNode) -> Color {
        switch node {
        case .solar: return Theme.solar
        case .battery: return Theme.stores
        case .home: return Theme.ink
        case .grid: return Theme.grid
        case .car: return Theme.car
        }
    }

    static func look(_ node: EnergyNode) -> TraceLook {
        let words = node.directions
        switch node {
        case .battery: return TraceLook(up: Theme.stores, down: Theme.gives, upWord: words.map { "↑ " + $0.up.uppercased() }, downWord: words.map { "↓ " + $0.down.uppercased() })
        case .grid: return TraceLook(up: Theme.grid, down: Theme.grid, upWord: words.map { "↑ " + $0.up.uppercased() }, downWord: words.map { "↓ " + $0.down.uppercased() })
        default: return TraceLook(up: color(node), down: color(node))
        }
    }
}

// MARK: - What the line under the chart says

/// The words for every slot of the chart on screen, made once per change of
/// data, so the line under the chart and the hero cost a subscript per
/// slot.
@Observable
@MainActor
final class PeriodText {
    /// What the hero says under a finger, as on the live trace: the node's
    /// own value and "14:30–15:00 · charging". No watts over a hole.
    struct Hero {
        var watts: Double?
        var signed: Double
        var word: String
        /// The series the value came from, when it is not the view's own.
        var node: EnergyNode? = nil
    }

    private(set) var slots: [String] = []
    private(set) var spans: (ClosedRange<Int>) -> String = { _ in "" }
    private(set) var heroes: [Hero] = []
    private(set) var heroSpans: (ClosedRange<Int>) -> Hero? = { _ in nil }

    func set(_ slots: [String], spans: @escaping (ClosedRange<Int>) -> String, heroes: [Hero] = [], heroSpans: @escaping (ClosedRange<Int>) -> Hero? = { _ in nil }) {
        self.slots = slots
        self.spans = spans
        self.heroes = heroes
        self.heroSpans = heroSpans
    }

    func text(_ scrub: ScrubModel) -> String? {
        if let i = scrub.index, slots.indices.contains(i) { return slots[i] }
        if let r = scrub.span, r.upperBound < slots.count { return spans(r) }
        return nil
    }

    func hero(_ scrub: ScrubModel) -> Hero? {
        if let i = scrub.index, heroes.indices.contains(i) { return heroes[i] }
        if let r = scrub.span, r.upperBound < heroes.count { return heroSpans(r) }
        return nil
    }
}

// MARK: - The stored past and the box's plan

/// Shared inputs for the continuous node timeline.
@MainActor
enum NodeHistory {
    static func ahead(_ node: EnergyNode, home: HomeModels, nowMs: Double) -> (kind: AheadPicture.Kind, slots: [AheadPicture.Mark])? {
        let plan = home.nodes.plan
        let marks: [AheadPicture.Mark]
        var kind = AheadPicture.Kind.plan
        switch node {
        case .battery, .grid:
            marks = (plan.plan?.slots ?? []).filter { $0.endMs > nowMs }.map { AheadPicture.Mark(startMs: $0.startMs, endMs: $0.endMs, watts: node == .battery ? $0.batteryW : $0.gridW) }
        case .solar, .home:
            kind = .forecast
            marks = plan.forecast.filter { $0.startMs + $0.durationMs > nowMs }.map { AheadPicture.Mark(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, watts: node == .solar ? $0.pvW : $0.loadW) }
        case .car:
            marks = home.loadpoints.points.flatMap { lp in
                (home.loadpoints.windows[lp.id] ?? lp.planWindows).filter { $0.toMs > nowMs }.map { w in
                    AheadPicture.Mark(startMs: w.fromMs, endMs: w.toMs, watts: w.peakW ?? (w.energyWh ?? 0) * 3_600_000 / max(1, w.toMs - w.fromMs))
                }
            }
        }
        return marks.isEmpty ? nil : (kind, marks)
    }

    /// The box's power means at their stored step. The car's ledger is
    /// hourly; those means stay hourly, including while zoomed in.
    static func samples(_ node: EnergyNode, home: HomeModels, fromMs: Double) -> [ChartSample] {
        if node == .car {
            guard home.nodes.carEnergy.loaded else { return [] }
            return home.nodes.carEnergy.hours.filter { $0.startMs + $0.lenMs > fromMs }.map { h in
                ChartSample(startMs: h.startMs, value: h.wh * 3_600_000 / max(1, h.lenMs))
            }
        }
        return home.nodes.history.samples(node, fromMs: fromMs).map { ChartSample(startMs: $0.startMs, value: $0.watts, fetching: $0.fetching) }
    }

}
