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
/// data, so the line under the chart costs a subscript per slot.
@Observable
@MainActor
final class PeriodText {
    private(set) var slots: [String] = []
    private(set) var spans: (ClosedRange<Int>) -> String = { _ in "" }

    func set(_ slots: [String], spans: @escaping (ClosedRange<Int>) -> String) {
        self.slots = slots
        self.spans = spans
    }

    func text(_ scrub: ScrubModel) -> String? {
        if let i = scrub.index, slots.indices.contains(i) { return slots[i] }
        if let r = scrub.span, r.upperBound < slots.count { return spans(r) }
        return nil
    }
}

// MARK: - Today and two days

/// Today on its fixed day, or the last two days, on the engine: each chosen
/// series with its band, the node's own with its body, holes as they are,
/// and the finger reading one slot at a time with what lies after it dimmed.
struct HistoryChartArea: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let scrub: ScrubModel
    let period: NodeView.Timebase
    let series: [EnergyNode]
    let text: PeriodText
    @State private var size: CGSize = .zero
    @State private var shown: YDomain?
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    var body: some View {
        let frame = ChartFrame(top: tag * 1.35 + 8, bottom: axis * 1.4 + 4, trailing: axis * 3.2)
        let plot = frame.plot(in: size).size
        let picture = build(plot)
        let own = picture?.layers.first
        ZStack {
            Color.clear
            if let picture, let own {
                HistorySurface(
                    picture: picture,
                    looks: Dictionary(uniqueKeysWithValues: picture.layers.compactMap { l in EnergyNode(rawValue: l.key).map { (l.key, NodeChartLook.look($0)) } }),
                    frame: frame,
                    words: ChartLabels(fetching: L("FETCHING…"), asOf: picture.asOfMs.map { NodeWords.format("AS OF %@", AppWords.clock($0, zone: .current)) }, now: NodeWords.text("NOW")),
                    axis: axis
                )
                ScrubOverlay(
                    track: ScrubTrack(
                        grid: picture.grid,
                        domain: picture.domain,
                        values: own.series.buckets.map(\.mean),
                        atMs: own.series.buckets.map(\.atMs),
                        tags: own.series.readouts.when.indices.map { own.series.readouts.when[$0] + "  " + (own.series.readouts.what[$0].components(separatedBy: " · ").first ?? "") },
                        landmarks: own.series.readouts.landmarks.union([0, max(0, picture.limit ?? 0)]),
                        color: NodeChartLook.color(node),
                        dimsAfter: true,
                        limit: picture.limit
                    ),
                    frame: frame,
                    model: scrub,
                    tagSize: tag,
                    spanTag: { r in own.series.readouts.when[r.lowerBound].components(separatedBy: "–").first! + "–" + (own.series.readouts.when[r.upperBound].components(separatedBy: "–").last ?? "") }
                )
            } else if let problem = home.nodes.history.problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: picture?.domain) { _, now in shown = now }
        .onChange(of: picture, initial: true) { _, now in words(now) }
        .accessibilityElement()
        .accessibilityLabel(node.title)
        .accessibilityChartDescriptor(PictureDescriptor(node: node, picture: picture))
    }

    /// The picture for the chosen series, the node's own first.
    private func build(_ plot: CGSize) -> HistoryPicture? {
        guard plot.width > 0, plot.height > 0 else { return nil }
        let clock = ZoneClock.of(.current)
        let now = site.minuteMs + 60_000
        let window = period == .today ? HistoryPicture.day(now, clock: clock) : HistoryPicture.twoDays(now)
        var inputs: [(key: String, samples: [ChartSample])] = []
        for n in series {
            let samples = Self.samples(n, home: home, fromMs: window.fromMs)
            if !samples.isEmpty || n == node { inputs.append((n.rawValue, samples)) }
        }
        let words = ReadoutWords(value: { AppWords.power(abs($0)) }, range: { "\(AppWords.decimal(PowerFormat.fixed(abs($0) / 1000, 1)))–\(AppWords.decimal(PowerFormat.fixed(abs($1) / 1000, 1)))" }, none: NodeWords.text("no data"))
        let weekday: @Sendable (Double) -> String = { ms in
            Date(timeIntervalSince1970: ms / 1000).formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: AppWords.language == .sv ? "sv_SE" : "en_US"))).uppercased().replacingOccurrences(of: ".", with: "")
        }
        return HistoryPicture.build(inputs, fromMs: window.fromMs, toMs: window.toMs, nowMs: now, size: plot, previous: shown, floor: node.scaleFloorW(), clock: clock, everyHours: period == .today ? 6 : 12, weekday: period == .today ? nil : weekday, words: words)
    }

    /// One node's five-minute means as the chart reads them. The box keeps
    /// no car tiles, so the car's hours stand in, each hour's mean power
    /// over its twelve five-minute steps.
    static func samples(_ node: EnergyNode, home: HomeModels, fromMs: Double) -> [ChartSample] {
        if node == .car {
            guard home.nodes.carEnergy.loaded else { return [] }
            return home.nodes.carEnergy.hours.filter { $0.startMs + $0.lenMs > fromMs }.flatMap { h -> [ChartSample] in
                let watts = h.wh * 3_600_000 / max(1, h.lenMs)
                return stride(from: h.startMs, to: h.startMs + h.lenMs, by: 300_000).map { ChartSample(startMs: $0, value: watts) }
            }
        }
        return home.nodes.history.samples(node, fromMs: fromMs).map { ChartSample(startMs: $0.startMs, value: $0.watts, fetching: $0.fetching) }
    }

    /// The line under the chart for each slot: the node's own mean and range,
    /// then each other series' mean, in its own words. A hidden series
    /// changes nothing here.
    private func words(_ picture: HistoryPicture?) {
        guard let picture, let own = picture.layers.first else { return text.set([], spans: { _ in "" }) }
        let others = picture.layers.dropFirst().compactMap { l in EnergyNode(rawValue: l.key).map { ($0, l.series) } }
        let slots = own.series.readouts.when.indices.map { i -> String in
            var parts = [own.series.readouts.when[i], own.series.readouts.what[i]]
            for (n, s) in others where s.readouts.what.indices.contains(i) {
                parts.append(n.title + " " + (s.readouts.what[i].components(separatedBy: " · ").first ?? ""))
            }
            return parts.joined(separator: " · ")
        }
        let readouts = own.series.readouts
        let directions = node.directions != nil
        text.set(slots) { r in
            let e = readouts.between(r.lowerBound, r.upperBound)
            let span = readouts.when[r.lowerBound].components(separatedBy: "–").first! + "–" + (readouts.when[r.upperBound].components(separatedBy: "–").last ?? "")
            return span + " · " + (directions ? NodeWords.format("↑ %@ ↓ %@", AppWords.energy(e.inWh), AppWords.energy(e.outWh)) : AppWords.energy(e.inWh))
        }
    }
}

/// A history as VoiceOver reads it: the chart's own slot means, in the
/// slot's length.
private struct PictureDescriptor: AXChartDescriptorRepresentable {
    let node: EnergyNode
    let picture: HistoryPicture?

    func makeChartDescriptor() -> AXChartDescriptor {
        let buckets = picture?.layers.first?.series.buckets ?? []
        let start = buckets.first?.startMs ?? 0, end = max(start + 1, buckets.last?.endMs ?? 1)
        let values = buckets.compactMap(\.mean)
        let lo = min(0, values.min() ?? 0), hi = max(lo + 1, values.max() ?? 1)
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: start...end, gridlinePositions: []) { Readouts.clock($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Power"), range: lo...hi, gridlinePositions: []) { AppWords.power(abs($0)) }
        let series = AXDataSeriesDescriptor(name: node.title, isContinuous: true, dataPoints: buckets.compactMap { b in
            b.mean.map { AXDataPoint(x: b.startMs, y: $0, additionalValues: [], label: Readouts.word(node, $0)) }
        })
        let minutes = Int(((picture?.stepMs ?? 1_800_000) / 60_000).rounded())
        return AXChartDescriptor(title: node.title, summary: NodeWords.format("%@-minute means", String(minutes)), xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

// MARK: - Ahead

/// The hours ahead on the engine: the plan's quarters as ghost bars for the
/// battery, the grid and the car; the forecast as a dashed line for the sun
/// and the home; the price under the same slots. The finger lights a plan
/// slot as its whole bar.
struct AheadChartArea: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let scrub: ScrubModel
    let text: PeriodText
    @State private var size: CGSize = .zero
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    var body: some View {
        let strip: CGFloat = 18
        let frame = ChartFrame(top: tag * 1.35 + 8, bottom: 6 + strip + axis * 1.4 + 4, trailing: axis * 3.2)
        let made = build(frame.plot(in: size).size)
        ZStack {
            Color.clear
            if let made {
                let picture = made.picture, bars = made.bars, prices = made.prices, currency = made.currency, forecast = made.forecast
                ChartSurface(drawing: AheadDrawing(picture: picture, look: NodeChartLook.look(node), frame: frame, axis: axis, nowWord: NodeWords.text("NOW"), strip: strip))
                    .equatable()
                ScrubOverlay(
                    track: ScrubTrack(
                        grid: picture.grid,
                        domain: picture.domain,
                        values: picture.values,
                        tags: picture.grid.count == 0 ? [] : (0..<picture.grid.count).map { i in
                            Readouts.clock(picture.grid.startMs(i)) + (picture.values[i].map { "  " + AppWords.power(abs($0)) } ?? "")
                        },
                        landmarks: [0, max(0, picture.grid.count - 1)],
                        color: NodeChartLook.color(node),
                        bars: picture.kind == .plan
                    ),
                    frame: frame,
                    model: scrub,
                    tagSize: tag,
                    spanTag: { r in Readouts.span(picture.grid.startMs(r.lowerBound), picture.grid.endMs(r.upperBound)) }
                )
                .onChange(of: picture, initial: true) { _, now in
                    let slots = (0..<now.grid.count).map { i in
                        Readouts.ahead(node, bars, prices, currency: currency, forecast: forecast, at: now.grid.startMs(i) + now.grid.stepMs / 2)?.what ?? " "
                    }
                    let whens = (0..<now.grid.count).map { Readouts.span(now.grid.startMs($0), now.grid.endMs($0)) }
                    text.set(zip(whens, slots).map { $0 + " · " + $1 }) { r in
                        Readouts.ahead(node, bars, prices, currency: currency, forecast: forecast, range: now.grid.startMs(r.lowerBound)...now.grid.endMs(r.upperBound)).map { $0.when + " · " + $0.what } ?? " "
                    }
                }
            } else {
                Text(placeholder).font(.footnote).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .accessibilityElement()
        .accessibilityLabel(L("Ahead"))
    }

    private var placeholder: String {
        switch node {
        case .solar, .home: return home.nodes.plan.forecastLoaded ? L("No forecast for the hours ahead yet.") : " "
        case .car: return home.loadpoints.points.isEmpty ? L("This box has no charger.") : " "
        default: return home.nodes.plan.problem ?? " "
        }
    }

    struct Built {
        var picture: AheadPicture
        var bars: [ChartSlot]
        var prices: [ChartPrice]
        var currency: String
        var forecast: Bool
    }

    private func build(_ plot: CGSize) -> Built? {
        guard plot.width > 0, plot.height > 0 else { return nil }
        let now = site.minuteMs
        let plan = home.nodes.plan
        let window = home.prices.prices
        let currency = window?.currency ?? "SEK"
        var bars: [ChartSlot] = []
        var forecast = false
        switch node {
        case .battery, .grid:
            bars = plan.ahead(nowMs: now).map { ChartSlot(startMs: $0.startMs, endMs: $0.endMs, watts: node == .battery ? $0.batteryW : $0.gridW, reason: $0.reason) }
        case .solar, .home:
            forecast = true
            bars = plan.forecastAhead(nowMs: now).map { ChartSlot(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, watts: node == .solar ? $0.pvW : $0.loadW) }
        case .car:
            let points = home.loadpoints.points
            for lp in points {
                for w in home.loadpoints.windows[lp.id] ?? lp.planWindows where w.toMs > now {
                    // A window that names no peak is drawn at its mean.
                    let mean: Double = (w.energyWh ?? 0) * 3_600_000 / max(1, w.toMs - w.fromMs)
                    bars.append(ChartSlot(startMs: w.fromMs, endMs: w.toMs, watts: w.peakW ?? mean))
                }
            }
        }
        guard !bars.isEmpty || node == .car else { return nil }
        let prices = (window?.slots ?? []).map { ChartPrice(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, minor: $0.totalMinor) }
        let slots: [(startMs: Double, endMs: Double, watts: Double?)] = bars.map { ($0.startMs, $0.endMs, $0.watts) }
        let rates: [(startMs: Double, endMs: Double, minor: Double)] = prices.map { ($0.startMs, $0.endMs, $0.minor) }
        let picture = AheadPicture.build(
            kind: forecast ? .forecast : .plan,
            slots: slots,
            prices: rates,
            nowMs: now,
            spanMs: PlanModel.aheadMs,
            size: plot,
            floor: node.scaleFloorW(),
            clock: ZoneClock.of(.current)
        )
        return Built(picture: picture, bars: bars, prices: prices, currency: currency, forecast: forecast)
    }
}
