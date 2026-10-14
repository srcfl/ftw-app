import Accessibility
import FTWKit
import os
import SwiftUI

#if DEBUG
enum TraceCost {
    static let log = Logger(subsystem: "energy.ftw.app", category: "frames")
}
#endif

/// One node of the flow, on one fixed screen: the reading now as the hero,
/// its last five minutes streaming as the chart, and the same chart for
/// today, the last two days and the hours ahead behind one picker in the
/// thumb's reach. A line under the chart says what the period adds up to,
/// the battery's mode sits under it, and a footer says how the reading
/// reaches the phone and how often the device reads.
///
/// The tap sends no request: the trace has been recording since the home
/// opened, so it opens drawn. History and the plan are asked for when the
/// view opens and kept for the next visit.
struct NodeView: View {
    let app: AppModel
    let home: HomeModels
    let node: EnergyNode
    let zoom: Namespace.ID
    @State private var scrub = ScrubModel()
    @State private var trace = NodeTraceModel()
    @State private var choosingMode = false
    @State private var timebase: Timebase
    @State private var readout: ChartReadout?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(app: AppModel, home: HomeModels, node: EnergyNode, zoom: Namespace.ID) {
        self.app = app
        self.home = home
        self.node = node
        self.zoom = zoom
        _timebase = State(initialValue: Timebase.remembered(node))
    }

    /// Live, today, the last two days and the hours ahead: one chart, one
    /// place.
    enum Timebase: String, CaseIterable, Hashable {
        case live, today, twoDays, ahead

        var label: String {
            switch self {
            case .live: return L("Live")
            case .today: return L("Today")
            case .twoDays: return L("48 h")
            case .ahead: return L("Ahead")
            }
        }

        /// The last choice for this node; debug builds take `-FTWPeriod
        /// ahead` and the like, for screenshots.
        static func remembered(_ node: EnergyNode) -> Timebase {
            #if DEBUG
            if let asked = UserDefaults.standard.string(forKey: "FTWPeriod").flatMap(Timebase.init(rawValue:)) { return asked }
            #endif
            return UserDefaults.standard.string(forKey: key(node)).flatMap(Timebase.init(rawValue:)) ?? .live
        }

        static func key(_ node: EnergyNode) -> String { "ftw.node.timebase.\(node.rawValue)" }
    }

    private var models: NodeModels { home.nodes }
    private var site: SiteModel { home.site }

    var body: some View {
        Group {
            // The accessibility sizes scroll; every other size is one fixed
            // page, chosen by the size and never by a fit.
            if typeSize.isAccessibilitySize {
                ScrollView { page(fill: false) }
            } else {
                page(fill: true)
            }
        }
        .background(Theme.ground)
        .navigationTitle(node.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            models.history.activate()
            models.plan.activate(forecast: node == .solar || node == .home)
            models.mode.activate()
            models.sources.activate(node)
            home.prices.activate()
            if node == .car { models.carEnergy.activate() }
            LaunchClock.mark("first content")
        }
        .onDisappear {
            models.history.deactivate()
            models.plan.deactivate(forecast: node == .solar || node == .home)
            models.mode.deactivate()
            models.sources.deactivate(node)
            home.prices.deactivate()
            if node == .car { models.carEnergy.deactivate() }
            trace.stopSound()
        }
        .onChange(of: timebase) { _, now in
            UserDefaults.standard.set(now.rawValue, forKey: Timebase.key(node))
            readout = nil
            scrub.lift()
        }
        .onChange(of: scrub.isDown) { _, down in
            if down { trace.hold(atMs: Date().timeIntervalSince1970 * 1000) } else { trace.release() }
        }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode)
        }
    }

    private func page(fill: Bool) -> some View {
        let timebases = Timebase.allCases.filter { $0 != .ahead || hasAhead }
        return VStack(alignment: .leading, spacing: 0) {
            NodeHero(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase)
                .padding(.horizontal, 20)
            NodeStatusRow(site: site, node: node)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            NodeChart(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, readout: $readout)
                .frame(minHeight: fill ? 180 : 240, idealHeight: 300, maxHeight: 340)
                .padding(.top, 8)
                .padding(.horizontal, 4)
            Picker(L("Period"), selection: $timebase.animation(.easeInOut(duration: 0.2))) {
                ForEach(timebases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("node.period")
            .padding(.horizontal, 20)
            .padding(.top, 12)
            RangeLine(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, readout: readout)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            if node == .battery {
                ModeRow(mode: models.mode, choose: { choosingMode = true })
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            } else if node == .car {
                CarRow(loadpoints: home.loadpoints, zoom: zoom)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
            if fill { Spacer(minLength: 8) }
            NodeFooter(site: site, node: node, live: models.live)
                .padding(.horizontal, 20)
                .padding(.top, fill ? 0 : 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: 640, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Ahead shows only where the box plans or forecasts for this node.
    private var hasAhead: Bool {
        switch node {
        case .battery, .grid: return models.plan.plan != nil
        case .solar, .home: return models.plan.forecastStamp != nil
        case .car: return !home.loadpoints.points.isEmpty
        }
    }
}

// MARK: - The trace

/// The live trace's state for one node's view: the geometry for the newest
/// reading, the one held still under a finger, and how the window springs
/// back on lift. Built once per reading.
@Observable
@MainActor
final class NodeTraceModel {
    private(set) var frame: TraceFrame?
    private(set) var held: TraceFrame?
    private(set) var frozenAtMs: Double?
    private(set) var catchUp: (fromMs: Double, at: Date)?
    @ObservationIgnored private var size: CGSize = .zero
    @ObservationIgnored private var playing = false

    /// What the chart and the hero read: held still while a finger is down.
    var shown: TraceFrame? { held ?? frame }

    /// `gapMs` is the silence the source in use allows before the line
    /// breaks.
    func build(_ samples: [LiveSample], node: EnergyNode, gapMs: Double, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let resized = size != self.size
        self.size = size
        let now = Date()
        let series = LiveSeries.build(
            samples,
            sourceGapMs: gapMs,
            windowMs: LiveTrace.windowMs,
            nowMs: now.timeIntervalSince1970 * 1000,
            size: size,
            previous: frame?.series.domain,
            floor: node.scaleFloorW()
        )
        frame = TraceFrame(series: series, previous: resized ? nil : frame?.series, arrivedAt: now)
        if playing, let last = series.last, series.domain.span > 0 {
            AXLiveAudioGraph.updateValue((last.v - series.domain.lower) / series.domain.span)
        }
    }

    func hold(atMs: Double) {
        held = frame
        frozenAtMs = atMs
        catchUp = nil
    }

    func release() {
        if let frozenAtMs { catchUp = (frozenAtMs, Date()) }
        held = nil
        frozenAtMs = nil
    }

    /// The live value as a tone, for VoiceOver.
    func toggleSound() {
        playing.toggle()
        if playing { AXLiveAudioGraph.start() } else { AXLiveAudioGraph.stop() }
    }

    func stopSound() {
        if playing { AXLiveAudioGraph.stop() }
        playing = false
    }
}

// MARK: - The hero

/// "1,8 kW" at 60 pt, the way it flows under it in its colour, and the
/// node's second fact on the right. Under a finger on the live trace it
/// gives the reading there and its time, and comes back with the spring.
private struct NodeHero: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let trace: NodeTraceModel
    let scrub: ScrubModel
    let timebase: NodeView.Timebase
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 60
    @ScaledMetric(relativeTo: .title2) private var unitSize: CGFloat = 22

    var body: some View {
        let loadpoints = home.loadpoints
        let fields = Flow.withLoadpointEV(site.session.fields, evW: loadpoints.stale ? 0 : Flow.loadpointChargeW(loadpoints.points))
        let car = loadpoints.points.first.flatMap { loadpoints.level($0) }
        let reading = NowFlow.readings(
            fields: fields,
            freshness: { site.freshness(fid: $0) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !loadpoints.points.isEmpty
        ).first { $0.node == node }
        let live = reading?.freshness.live ?? false
        let under = timebase == .live ? fingered : nil
        let watts = under?.watts ?? reading?.watts
        let word = under?.word ?? reading?.word ?? L("Your box sends no reading for this.")
        let tone = under.map { Readouts.tone(node, $0.signed) } ?? reading?.tone ?? .muted

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                figure(watts)
                    .foregroundStyle(live || under != nil ? Theme.ink : Theme.ink3)
                Text(word)
                    .font(.headline)
                    .foregroundStyle(live || under != nil ? Theme.color(tone) : Theme.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            SecondFact(site: site, node: node, home: home, reading: reading, live: live)
        }
        .transaction { $0.animation = scrub.isDown ? nil : Theme.spring }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("node.hero")
    }

    private func figure(_ watts: Double?) -> some View {
        let parts = watts.map(PowerFormat.parts)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.map { AppWords.decimal($0.text) } ?? "—")
                .font(Theme.figure(figureSize))
                .tracking(-1)
                .contentTransition(.numericText(value: watts ?? 0))
            Text(parts?.unit ?? "")
                .font(.system(size: unitSize, weight: .medium))
                .foregroundStyle(Theme.ink2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// The reading under a finger on the trace, or the mean of two
    /// fingers' span.
    private var fingered: (watts: Double, signed: Double, word: String)? {
        guard let frame = trace.shown else { return nil }
        let readings = frame.readings
        if let i = scrub.index, readings.indices.contains(i) {
            let r = readings[i]
            return (abs(r.v), r.v, NodeLive.when(r.t, Readouts.word(node, r.v)))
        }
        if let span = scrub.span, span.upperBound < readings.count {
            let slice = readings[span]
            let mean = slice.map(\.v).reduce(0, +) / Double(slice.count)
            let from = slice.first!.t, to = slice.last!.t
            return (abs(mean), mean, Readouts.seconds(from) + "–" + Readouts.seconds(to) + " · " + NodeWords.format("average %@", AppWords.power(abs(mean))))
        }
        return nil
    }
}

/// The fact beside the figure that only this node has: the battery's level
/// as the 10-cell meter, the car's level and where it comes from, what the
/// grid costs an hour, the sun against its forecast, or the home's sources.
private struct SecondFact: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let reading: NodeReading?
    let live: Bool
    @ScaledMetric(relativeTo: .title) private var levelSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch node {
            case .battery:
                if let pct = reading?.levelPct {
                    Text(AppWords.percent(pct))
                        .font(Theme.figure(levelSize))
                        .foregroundStyle(live ? Theme.ink : Theme.ink3)
                        .contentTransition(.numericText(value: pct))
                    CellMeter(pct: pct, tint: Theme.stores, live: live)
                        .frame(width: 74, height: 4)
                }
            case .car:
                if let lp = home.loadpoints.points.first, let level = home.loadpoints.level(lp) {
                    Text(AppWords.percent(level.pct))
                        .font(Theme.figure(levelSize))
                        .foregroundStyle(level.origin == .assumed || level.origin == .unconfirmed ? Theme.ink3 : Theme.ink)
                    Text(EVText.originShort(level, zone: home.loadpoints.zone))
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                }
            case .grid:
                let price = currentPrice
                if let text = NodeLive.gridCost(watts: site.session.fields[node.fid] ?? 0, priceMinor: price?.minor, currency: price?.currency ?? "SEK") {
                    Text(text)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            case .solar:
                let made = reading?.watts ?? 0
                let forecast = home.nodes.plan.forecastAhead(nowMs: site.nowMs).first { $0.startMs <= site.nowMs && site.nowMs < $0.startMs + $0.durationMs }?.pvW
                if let text = NodeLive.solarShare(madeW: made, forecastW: forecast) {
                    Text(text)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            case .home:
                Text(L("calculated"))
                    .font(.headline)
                    .foregroundStyle(Theme.ink2)
                let f = site.session.fields
                if let shares = NodeLive.homeShares(pvW: f[Contract.FID.pvW] ?? 0, batteryW: f[Contract.FID.batteryW] ?? 0, gridW: f[Contract.FID.gridW] ?? 0) {
                    ShareBar(sun: shares.sun, battery: shares.battery, grid: shares.grid, live: live)
                        .frame(width: 74, height: 4)
                }
            }
        }
        .fixedSize()
    }

    private var currentPrice: (minor: Double, currency: String)? {
        guard let window = home.prices.prices else { return nil }
        let now = site.nowMs
        return window.slots.first { $0.startMs <= now && now < $0.startMs + $0.durationMs }.map { ($0.totalMinor, window.currency) }
    }
}

/// The home's power by source, as one 4 pt bar: sun, battery, grid.
private struct ShareBar: View {
    let sun: Double
    let battery: Double
    let grid: Double
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array([(sun, Theme.solar), (battery, Theme.gives), (grid, Theme.grid)].enumerated()), id: \.offset) { _, part in
                    if part.0 > 0.01 {
                        Capsule().fill(live ? part.1 : Theme.ink3).frame(width: max(2, (geo.size.width - 2) * part.0))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The chart

/// Over the chart: whether this node's reading is live, and from which
/// device. `● LIVE · SUNGROW`, or `○ AS OF 14:05`: a clock time, never a
/// count of seconds.
private struct NodeStatusRow: View {
    let site: SiteModel
    let node: EnergyNode
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10.5

    var body: some View {
        let f = site.freshness(node)
        let text = NodeLive.status(node, f, nowMs: site.minuteMs, zone: .current)
        // Only the dot is lit; the words are ink.
        let dot = String(text.prefix(1)), rest = String(text.dropFirst())
        Text("\(Text(verbatim: dot).foregroundStyle(f.live ? Theme.live : Theme.ink3))\(Text(verbatim: rest).foregroundStyle(f.live ? Theme.ink2 : Theme.ink3))")
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityIdentifier("node.status")
            .contentTransition(.opacity)
            .animation(.default, value: text)
    }
}

/// One place for the node's chart. Live streams the trace; today, the
/// last two days and the hours ahead draw their own charts in the same
/// frame. A switch cross-fades in 0.2 s and the scale does not morph.
private struct NodeChart: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let trace: NodeTraceModel
    let scrub: ScrubModel
    let timebase: NodeView.Timebase
    @Binding var readout: ChartReadout?

    var body: some View {
        ZStack {
            switch timebase {
            case .live:
                LiveChartArea(site: site, node: node, live: home.nodes.live, trace: trace, scrub: scrub)
                    .transition(.opacity)
            default:
                PeriodChart(site: site, node: node, period: timebase, models: home.nodes, prices: home.prices, loadpoints: home.loadpoints, onScrub: { readout = $0 })
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("node.period.chart")
            }
        }
    }
}

/// The streaming trace and the finger on it. It reads the ring of live
/// readings once per reading and builds the geometry then; between
/// readings the surface only scrolls.
private struct LiveChartArea: View {
    let site: SiteModel
    let node: EnergyNode
    let live: LiveTrace
    let trace: NodeTraceModel
    let scrub: ScrubModel
    @State private var size: CGSize = .zero
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    var body: some View {
        let revision = live.revision
        let chartFrame = ChartFrame(top: tag * 1.35 + 8, bottom: 6, trailing: axis * 3.2)
        let look = Self.look(node)
        let isLive = site.freshness(node).live
        ZStack {
            // Takes the whole frame before the first reading, so the
            // geometry knows its size.
            Color.clear
            if let frame = trace.shown {
                LiveTraceSurface(frame: frame, look: look, live: isLive, chartFrame: chartFrame, frozenAtMs: trace.frozenAtMs, catchUp: trace.catchUp, axisSize: axis)
                LiveScrubOverlay(
                    frame: frame,
                    chartFrame: chartFrame,
                    model: scrub,
                    viewMs: trace.frozenAtMs ?? Date().timeIntervalSince1970 * 1000,
                    look: look,
                    tagSize: tag,
                    tag: { NodeLive.tag($0.t, watts: $0.v) },
                    spanTag: { r in
                        let slice = frame.readings[r]
                        let mean = slice.map(\.v).reduce(0, +) / Double(max(1, slice.count))
                        return Readouts.seconds(slice.first!.t) + "–" + Readouts.seconds(slice.last!.t) + "  " + NodeWords.format("avg %@", AppWords.power(abs(mean)))
                    }
                )
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: revision, initial: true) { rebuild(chartFrame) }
        .onChange(of: size) { rebuild(chartFrame) }
        .accessibilityElement()
        .accessibilityLabel(L("Live, the last five minutes"))
        .accessibilityChartDescriptor(LiveDescriptor(node: node, readings: trace.frame?.readings ?? []))
        .accessibilityAction(named: L("Play as sound")) { trace.toggleSound() }
        .accessibilityIdentifier("node.live.chart")
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    #if DEBUG
    /// With `-FTWAutoScrub YES`, as on the price chart: a thumb back and
    /// forth over the trace for ten seconds, then two fingers for three,
    /// through the scrub model the finger moves. `-FTWAutoScrubAfter 300`
    /// waits for a full window first.
    private func autoScrub() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "FTWAutoScrub") else { return }
        let wait = defaults.double(forKey: "FTWAutoScrubAfter")
        try? await Task.sleep(for: .seconds(wait > 0 ? wait : 2))
        func reading(_ along: Double) -> Int? {
            guard let frame = trace.shown else { return nil }
            let now = trace.frozenAtMs ?? Date().timeIntervalSince1970 * 1000
            return SlotGrid.nearest(frame.times, to: now - (1 - along) * LiveTrace.windowMs)
        }
        let began = ContinuousClock.now
        while ContinuousClock.now - began < .seconds(10) {
            let t = (ContinuousClock.now - began) / .milliseconds(1_600)
            let phase = t.truncatingRemainder(dividingBy: 2)
            if let i = reading(0.05 + 0.95 * (phase < 1 ? phase : 2 - phase)), let frame = trace.shown {
                scrub.move(to: i, landmark: frame.landmarks.contains(i))
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        if let a = reading(0.45), let b = reading(0.8) { scrub.spread(a, b) }
        try? await Task.sleep(for: .seconds(3))
        scrub.lift()
    }
    #endif

    private func rebuild(_ chartFrame: ChartFrame) {
        let plot = chartFrame.plot(in: size).size
        #if DEBUG
        let began = ContinuousClock.now
        defer { TraceCost.log.debug("trace built in \((ContinuousClock.now - began) / .microseconds(1), format: .fixed(precision: 0)) µs") }
        #endif
        trace.build(live.samples(node, sinceMs: Date().timeIntervalSince1970 * 1000 - LiveTrace.windowMs - 10_000), node: node, gapMs: site.readingGapMs, size: plot)
    }

    /// Each side of zero in its direction's colour: the battery cyan
    /// storing and gold giving, the grid magenta both ways.
    static func look(_ node: EnergyNode) -> TraceLook {
        let words = node.directions
        switch node {
        case .battery: return TraceLook(up: Theme.stores, down: Theme.gives, upWord: words.map { "↑ " + $0.up.uppercased() }, downWord: words.map { "↓ " + $0.down.uppercased() })
        case .grid: return TraceLook(up: Theme.grid, down: Theme.grid, upWord: words.map { "↑ " + $0.up.uppercased() }, downWord: words.map { "↓ " + $0.down.uppercased() })
        default:
            let c = Theme.color(NodeLook.tone(node))
            return TraceLook(up: c, down: c)
        }
    }
}

/// The trace as VoiceOver reads it: every reading, in watts.
private struct LiveDescriptor: AXChartDescriptorRepresentable {
    let node: EnergyNode
    let readings: [LiveSample]

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = readings.first?.t ?? 0, end = max(start + 1, readings.last?.t ?? 1)
        let lo = min(0, readings.map(\.v).min() ?? 0), hi = max(lo + 1, readings.map(\.v).max() ?? 1)
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: start...end, gridlinePositions: []) { Readouts.seconds($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Power"), range: lo...hi, gridlinePositions: []) { AppWords.power(abs($0)) }
        let series = AXDataSeriesDescriptor(name: node.title, isContinuous: true, dataPoints: readings.map {
            AXDataPoint(x: $0.t, y: $0.v, additionalValues: [], label: Readouts.word(node, $0.v))
        })
        return AXChartDescriptor(title: node.title, summary: L("Live, the last five minutes"), xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

// MARK: - Under the chart

/// Two reserved lines: what the period adds up to, or under a finger what
/// it adds up to so far. The page never moves.
private struct RangeLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let trace: NodeTraceModel
    let scrub: ScrubModel
    let timebase: NodeView.Timebase
    let readout: ChartReadout?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: "\n")
            Text(text)
                .accessibilityIdentifier("chart.readout")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink2)
        .lineLimit(typeSize.isAccessibilitySize ? 5 : 2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    private var text: String {
        guard timebase == .live else {
            if let readout { return readout.when + "  " + readout.what }
            return PeriodWords.summary(site: site, node: node, period: timebase, models: home.nodes, loadpoints: home.loadpoints)
        }
        guard let frame = trace.shown else { return " " }
        let runs = frame.series.runs
        if let i = scrub.index, frame.readings.indices.contains(i) {
            return NodeLive.soFar(node, NodeLive.energy(runs, untilMs: frame.readings[i].t))
        }
        if let span = scrub.span, span.upperBound < frame.readings.count {
            let a = NodeLive.energy(runs, untilMs: frame.readings[span.lowerBound].t)
            let b = NodeLive.energy(runs, untilMs: frame.readings[span.upperBound].t)
            return NodeLive.between(node, (b.inWh - a.inWh, b.outWh - a.outWh))
        }
        return NodeLive.range(node, NodeLive.energy(runs))
    }
}

/// `VIA RELAY · READS EVERY 1 S`: how the reading reaches the phone, and
/// how often the device itself reads, from its readings. A switch of path
/// changes the first word and nothing else.
private struct NodeFooter: View {
    let site: SiteModel
    let node: EnergyNode
    let live: LiveTrace
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10

    var body: some View {
        let points = live.points(node.fid, sinceMs: site.nowMs - LiveTrace.windowMs)
        // A value that never changed in the window says nothing of how often
        // the device reads, so the footer does not guess.
        let period = LiveSeries.period(of: points.map { LiveSample(t: $0.t, v: $0.v) })
        Text(NodeLive.footer(site.carrier, periodMs: period))
            .font(.system(size: size, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.ink3)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityIdentifier("node.footer")
    }
}

/// The battery's one extra row: `Mode · Balanced ›`.
private struct ModeRow: View {
    let mode: ModeModel
    let choose: () -> Void

    var body: some View {
        if mode.mayControl {
            Button(action: choose) {
                HStack(spacing: 6) {
                    Text(L("Mode")).foregroundStyle(Theme.ink2)
                    Text(verbatim: "·").foregroundStyle(Theme.ink3)
                    Text(mode.outcome?.text ?? mode.label ?? "—")
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .lineLimit(2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!mode.canControl)
            .accessibilityIdentifier("node.mode.change")
            .animation(Theme.spring, value: mode.outcome)
            .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in Self.feedback(tone) }
        } else if let label = mode.label {
            HStack(spacing: 6) {
                Text(L("Mode")).foregroundStyle(Theme.ink2)
                Text(verbatim: "·").foregroundStyle(Theme.ink3)
                Text(label).foregroundStyle(Theme.ink)
            }
            .font(.subheadline)
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    static func feedback(_ tone: EVText.Outcome.Tone?) -> SensoryFeedback? {
        switch tone {
        case .done?: return .success
        case .warning?: return .warning
        case .failed?: return .error
        default: return nil
        }
    }
}

/// The car's one extra row: what it does now, into the car view.
private struct CarRow: View {
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID

    var body: some View {
        if let lp = loadpoints.points.first {
            NavigationLink(value: HomeRoute.car(lp.id)) {
                HStack(spacing: 6) {
                    Text(EVText.status(lp, zone: loadpoints.zone)).foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .lineLimit(1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: HomeRoute.car(lp.id), in: zoom)
            .accessibilityIdentifier("node.car.open")
        }
    }
}

// MARK: - Today, two days, ahead

/// Today, the last two days or the hours ahead, in the live chart's frame.
/// These keep their own charts until WP7 moves them onto the engine.
private struct PeriodChart: View {
    let site: SiteModel
    let node: EnergyNode
    let period: NodeView.Timebase
    let models: NodeModels
    let prices: PriceModel
    let loadpoints: LoadpointsModel
    let onScrub: (ChartReadout?) -> Void

    var body: some View {
        Group {
            switch period {
            case .ahead: ahead
            default: past
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fromMs: Double {
        period == .today ? models.history.midnightMs : site.nowMs - HistoryModel.spanMs
    }

    /// The hour the history is drawn to: the tiles end at the last five
    /// minutes, and the axis at now.
    private var toMs: Double { (site.nowMs / 60_000).rounded(.up) * 60_000 }

    @ViewBuilder private var past: some View {
        let stride = period == .today ? 6 : 12
        if node == .car {
            if models.carEnergy.loaded {
                CarHoursChart(hours: models.carEnergy.hours, fromMs: fromMs, toMs: toMs, strideHours: stride, onScrub: onScrub).equatable()
            } else {
                Placeholder(text: models.carEnergy.problem)
            }
        } else if !models.history.available {
            Placeholder(text: L("Your box keeps no history."))
        } else if models.history.frame != nil {
            HistoryChart(node: node, samples: models.history.samples(node, fromMs: fromMs), fromMs: fromMs, toMs: toMs, look: NodeLook.look(node), strideHours: stride, onScrub: onScrub)
                .equatable()
        } else {
            Placeholder(text: models.history.problem)
        }
    }

    @ViewBuilder private var ahead: some View {
        let now = site.nowMs
        let window = prices.prices
        let priceBars = (window?.slots ?? []).map { AheadChart.Price(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, minor: $0.totalMinor) }
        switch node {
        case .battery, .grid:
            let slots = models.plan.ahead(nowMs: now)
            if slots.isEmpty {
                Placeholder(text: models.plan.loaded ? nil : models.plan.problem)
            } else {
                AheadChart(
                    node: node,
                    bars: slots.map { AheadChart.Bar(startMs: $0.startMs, endMs: $0.endMs, watts: node == .battery ? $0.batteryW : $0.gridW, reason: $0.reason) },
                    prices: slots.compactMap { s in s.priceMinor.map { AheadChart.Price(startMs: s.startMs, endMs: s.endMs, minor: $0) } },
                    currency: window?.currency ?? "SEK",
                    nowMs: now,
                    look: NodeLook.look(node),
                    onScrub: onScrub
                ).equatable()
            }
        case .solar, .home:
            let slots = models.plan.forecastAhead(nowMs: now)
            if slots.isEmpty {
                Placeholder(text: models.plan.forecastLoaded ? L("No forecast for the hours ahead yet.") : nil)
            } else {
                AheadChart(
                    node: node,
                    bars: slots.map { AheadChart.Bar(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, watts: node == .solar ? $0.pvW : $0.loadW) },
                    prices: slots.compactMap { s in s.priceMinor.map { AheadChart.Price(startMs: s.startMs, endMs: s.startMs + s.durationMs, minor: $0) } },
                    currency: window?.currency ?? "SEK",
                    nowMs: now,
                    look: NodeLook.look(node),
                    forecast: true,
                    onScrub: onScrub
                ).equatable()
            }
        case .car:
            let windows = loadpoints.points.flatMap { loadpoints.windows[$0.id] ?? $0.planWindows }
            AheadChart(
                node: .car,
                bars: windows.filter { $0.toMs > now }.map { w in
                    // A window that names no peak is drawn at its mean.
                    AheadChart.Bar(startMs: w.fromMs, endMs: w.toMs, watts: w.peakW ?? (w.energyWh ?? 0) * 3_600_000 / max(1, w.toMs - w.fromMs))
                },
                prices: priceBars,
                currency: window?.currency ?? "SEK",
                nowMs: now,
                look: NodeLook.look(.car),
                onScrub: onScrub
            ).equatable()
        }
    }

}

/// The line under today, the last two days and the hours ahead.
private enum PeriodWords {
    @MainActor
    static func summary(site: SiteModel, node: EnergyNode, period: NodeView.Timebase, models: NodeModels, loadpoints: LoadpointsModel) -> String {
        let fromMs = period == .today ? models.history.midnightMs : site.nowMs - HistoryModel.spanMs
        let zone = TimeZone.current
        switch period {
        case .live, .today, .twoDays:
            if node == .car {
                guard models.carEnergy.loaded else { return " " }
                let wh = models.carEnergy.wh(sinceMs: fromMs)
                return NodeWords.format(period == .today ? "Today: charged %@" : "48 h: charged %@", AppWords.energy(wh))
            }
            guard let frame = models.history.frame, frame.points > 0 else { return models.history.problem ?? " " }
            let e = EnergyToday.sum(models.history.samples(node, fromMs: fromMs), fromMs: fromMs)
            return NodeSummary.energy(node, e, today: period == .today)
        case .ahead:
            let now = site.nowMs
            // "No plan" only once the box has answered without one; until
            // then the line keeps its place.
            let noPlan = models.plan.plan == nil && !models.plan.loaded
            let noForecast = models.plan.forecastStamp == nil && !models.plan.forecastLoaded
            switch node {
            case .battery where noPlan, .grid where noPlan:
                return models.plan.problem ?? " "
            case .solar where noForecast, .home where noForecast:
                return " "
            case .battery: return PlanText.battery(models.plan.ahead(nowMs: now), stale: models.plan.plan?.stale ?? false, nowMs: now, zone: zone)
            case .grid: return PlanText.grid(models.plan.ahead(nowMs: now), stale: models.plan.plan?.stale ?? false)
            case .solar: return PlanText.solar(models.plan.forecastAhead(nowMs: now))
            case .home: return PlanText.home(models.plan.forecastAhead(nowMs: now))
            case .car:
                guard !loadpoints.points.isEmpty else { return L("This box has no charger.") }
                let windows = loadpoints.points.flatMap { loadpoints.windows[$0.id] ?? $0.planWindows }
                return PlanText.car(windows, nowMs: now, zone: loadpoints.zone)
            }
        }
        }
}

/// The shape of a chart that has not arrived, with what is happening.
private struct Placeholder: View {
    let text: String?

    var body: some View {
        VStack(spacing: 6) {
            if let text {
                Text(text).font(.footnote).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.hairline)
                    .redacted(reason: .placeholder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// The energy line under a node's history, in the node's own words.
enum NodeSummary {
    static func energy(_ node: EnergyNode, _ e: EnergyToday, today: Bool) -> String {
        let a = AppWords.energy(e.inWh), b = AppWords.energy(e.outWh)
        var text: String
        switch node {
        case .solar: text = today ? NodeWords.format("Today: made %@", a) : NodeWords.format("48 h: made %@", a)
        case .battery: text = today ? NodeWords.format("Today: charged %@ · gave %@", a, b) : NodeWords.format("48 h: charged %@ · gave %@", a, b)
        case .home: text = today ? NodeWords.format("Today: used %@", a) : NodeWords.format("48 h: used %@", a)
        case .grid: text = today ? NodeWords.format("Today: bought %@ · sold %@", a, b) : NodeWords.format("48 h: bought %@ · sold %@", a, b)
        case .car: text = today ? NodeWords.format("Today: charged %@", a) : NodeWords.format("48 h: charged %@", a)
        }
        if e.missingMs >= 600_000 {
            let minutes = Int((e.missingMs / 60_000).rounded())
            text += " · " + NodeWords.format("%@ not recorded", minutes < 120 ? "\(minutes) min" : "\(minutes / 60) h")
        }
        return text
    }
}

extension NodeLook {
    /// The colour of a node's curve.
    static func tone(_ node: EnergyNode) -> Flow.Tone {
        switch node {
        case .solar: return .solar
        case .battery: return .battery
        case .home: return .house
        case .grid: return .importing
        case .car: return .ev
        }
    }

    /// One colour pair per node for all its charts: the battery in its own
    /// colour, giving power in the same colour lighter; the grid red when
    /// buying and green when selling, as on Now. Grey when not live.
    static func look(_ node: EnergyNode, live: Bool = true) -> ChartLook {
        let words = node.directions
        guard live else {
            return ChartLook(up: Theme.ink3, down: Theme.ink3.opacity(0.6), line: Theme.ink3, upWord: words?.up, downWord: words?.down)
        }
        switch node {
        case .battery:
            return ChartLook(up: Theme.stores, down: Theme.gives, line: Theme.ink2, upWord: words?.up, downWord: words?.down)
        case .grid:
            return ChartLook(up: Theme.grid, down: Theme.grid, line: Theme.grid, upWord: words?.up, downWord: words?.down)
        default:
            let c = Theme.color(tone(node))
            return ChartLook(up: c, down: c, line: c)
        }
    }

}
