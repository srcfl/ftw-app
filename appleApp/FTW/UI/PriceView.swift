import Charts
import FTWKit
import SwiftUI

/// The price: what power costs now, in one header row, and the hours ahead
/// as one line coloured by level, with now, the cheapest hours and the
/// average marked. A finger on the line says the price there and what the
/// plan does then. One screen.
struct PriceView: View {
    let home: HomeModels

    var body: some View {
        FitScreen(spacing: 10) { fill in
            PriceBody(site: home.site, prices: home.prices, plan: home.nodes.planShare, fill: fill)
        }
        .navigationTitle(L("Electricity price"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            home.prices.activate()
            home.nodes.plan.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            home.prices.deactivate()
            home.nodes.plan.deactivate()
        }
    }
}

private struct PriceBody: View {
    let site: SiteModel
    let prices: PriceModel
    let plan: PlanShare
    let fill: Bool
    @State private var readout: ChartReadout?

    var body: some View {
        // The chart marks the minute: the now dot moves once a minute.
        let minute = (site.nowMs / 60_000).rounded(.down) * 60_000
        if let window = prices.prices {
            let summary = PriceStrip.summary(window, nowMs: minute)
            PriceHeader(window: window, current: summary.current)
            VStack(alignment: .leading, spacing: 8) {
                if summary.bars.isEmpty {
                    Text(L("No prices ahead yet."))
                        .font(.footnote)
                        .foregroundStyle(Theme.fgMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PriceChart(bars: summary.bars, mean: summary.meanMinor, cheapest: summary.cheapest, currency: window.currency, nowMs: minute, plan: plan.entry, onScrub: { readout = $0 })
                        .equatable()
                        .frame(minHeight: fill ? 160 : 220)
                        .accessibilityIdentifier("price.chart")
                }
                ReadoutLine(readout: readout, otherwise: line(summary, window.currency))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxHeight: fill ? .infinity : nil)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        } else {
            Text(L("Reading the prices from your box…"))
                .font(.footnote)
                .foregroundStyle(Theme.fgMuted)
        }
    }

    /// "Cheapest 02–04 · 59.0 öre/kWh on average"
    private func line(_ summary: PriceStrip.Summary, _ currency: String) -> String {
        guard let c = summary.cheapest else { return " " }
        return NodeWords.format("Cheapest %@ · %@ on average", Readouts.span(c.startMs, c.endMs), Readouts.price(c.meanMinor, currency))
    }
}

/// "Elpris 82,0 öre/kWh" in one row, and the zone and what the price holds
/// under it.
private struct PriceHeader: View {
    let window: Prices
    let current: PriceSlot?

    var body: some View {
        let unit = PriceUnits.unit(window.currency)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("Electricity price"))
                    .font(.headline)
                    .foregroundStyle(Theme.fg)
                Spacer(minLength: 8)
                Text(current.map { AppWords.decimal(PriceStrip.text($0.totalMinor, window.currency)) } ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.fg)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit.perKwh)
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
            }
            Text([window.zone.isEmpty ? nil : window.zone, PriceGlance.text(PriceGlance.included(window.slots))].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The app's price chart: the shared line, a finger that reads it, and
/// the line growing into shape when prices change.
struct PriceChart: View, Equatable {
    let bars: [PriceStrip.Bar]
    let mean: Double?
    let cheapest: PriceStrip.Block?
    let currency: String
    let nowMs: Double
    let plan: PlanEntry?
    var onScrub: (ChartReadout?) -> Void = { _ in }
    @State private var selected: Date?
    @State private var range: ClosedRange<Date>?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.bars == b.bars && a.mean == b.mean && a.cheapest == b.cheapest && a.currency == b.currency && a.nowMs == b.nowMs && a.plan == b.plan
    }

    var body: some View {
        let points = bars.map { HistoryPlot.Point(t: $0.startMs, v: PriceUnits.display($0.minor, currency), kind: .measured, run: 0, id: $0.startMs) }
        let ends = Dictionary(bars.map { ($0.startMs, $0.endMs) }, uniquingKeysWith: { a, _ in a })
        MovingPoints(points: points) { drawn, _, _ in
            PriceLineChart(
                points: drawn.map { PricePoint(startMs: $0.id, endMs: ends[$0.id] ?? $0.id, value: $0.v) },
                nowMs: nowMs,
                mean: mean.map { PriceUnits.display($0, currency) },
                cheapest: cheapest.map { $0.startMs...$0.endMs },
                cheapestLabel: L("Cheapest"),
                meanLabel: mean.map { NodeWords.format("avg %@", AppWords.decimal(PriceStrip.text($0, currency))) },
                palette: .ink,
                zone: .current,
                selected: selected
            )
        }
        .chartScrub(selected: $selected, range: $range, slot: { d in
            let ms = d.timeIntervalSince1970 * 1000
            return bars.first { $0.startMs <= ms && ms < $0.endMs }?.startMs
        }, landmark: { slot in landmarks.contains(slot) })
        .onChange(of: selected) { _, _ in report() }
        .onChange(of: range) { _, _ in report() }
        .dynamicTypeSize(...chartTextCap)
        .accessibilityChartDescriptor(PriceDescriptor(bars: bars, currency: currency))
    }

    private var chartPrices: [ChartPrice] { bars.map { ChartPrice(startMs: $0.startMs, endMs: $0.endMs, minor: $0.minor) } }

    /// Now, the edges of the cheapest hours, the dearest and the cheapest.
    private var landmarks: Set<Double> {
        var out = Set<Double>()
        if let now = bars.first(where: { $0.current }) { out.insert(now.startMs) }
        if let c = cheapest {
            out.insert(c.startMs)
            if let last = bars.last(where: { $0.startMs < c.endMs }) { out.insert(last.startMs) }
        }
        if let hi = bars.max(by: { $0.minor < $1.minor }) { out.insert(hi.startMs) }
        if let lo = bars.min(by: { $0.minor < $1.minor }) { out.insert(lo.startMs) }
        return out
    }

    private func report() {
        if let range {
            onScrub(Readouts.price(chartPrices, currency: currency, range: range.lowerBound.timeIntervalSince1970 * 1000...range.upperBound.timeIntervalSince1970 * 1000))
        } else if let selected {
            onScrub(Readouts.price(chartPrices, currency: currency, plan: plan, at: selected.timeIntervalSince1970 * 1000))
        } else {
            onScrub(nil)
        }
    }
}

/// The prices as VoiceOver reads them: a slot a step.
struct PriceDescriptor: AXChartDescriptorRepresentable {
    let bars: [PriceStrip.Bar]
    let currency: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = bars.map { PriceUnits.display($0.minor, currency) }
        let lo = min(0, values.min() ?? 0), hi = max(lo + 1, values.max() ?? 1)
        let start = bars.first?.startMs ?? 0, end = max(start + 1, bars.last?.endMs ?? 1)
        let unit = PriceUnits.unit(currency).perKwh
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: start...end, gridlinePositions: []) { Readouts.clock($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Electricity price"), range: lo...hi, gridlinePositions: []) { "\(AppWords.decimal(PowerFormat.fixed($0, 1))) \(unit)" }
        let series = AXDataSeriesDescriptor(name: L("Electricity price"), isContinuous: false, dataPoints: bars.map {
            AXDataPoint(x: $0.startMs, y: PriceUnits.display($0.minor, currency))
        })
        return AXChartDescriptor(title: L("Electricity price"), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
