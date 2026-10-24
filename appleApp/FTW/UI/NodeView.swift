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
/// today, the last two days and the hours ahead behind one picker. The chart
/// takes the room; the picker, the line that says what the period adds up
/// to and the node's extra row sit over the footer, in the thumb's reach.
/// The footer says how the reading reaches the phone, from which device and
/// how often it reads. The status line under the title is the only one.
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
    @State private var text = PeriodText()
    @State private var series: [EnergyNode]
    @State private var enlarged = false
    @Namespace private var chartZoom
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `opening`: the chart to open on, as History opens a node's day;
    /// otherwise the viewer's last choice for this node.
    init(app: AppModel, home: HomeModels, node: EnergyNode, zoom: Namespace.ID, opening: Timebase? = nil) {
        self.app = app
        self.home = home
        self.node = node
        self.zoom = zoom
        _timebase = State(initialValue: opening ?? Timebase.remembered(node))
        _series = State(initialValue: SeriesChoice.load(node))
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
                ScrollView { page(chartMax: nil) }
            } else {
                // The chart grows to half the screen's height, never more.
                GeometryReader { geo in
                    page(chartMax: (geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom) / 2)
                }
            }
        }
        .background(Theme.ground)
        .navigationTitle(node.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            models.history.activate()
            // Every node: Today draws the sun's and the home's forecast as
            // the rest of the day, beside whatever series it shows.
            models.plan.activate(forecast: true)
            models.mode.activate()
            models.sources.activate(node)
            home.prices.activate()
            if node == .car { models.carEnergy.activate() }
            if node == .home { home.savings.activate() }
            LaunchClock.mark("first content")
        }
        .onDisappear {
            models.history.deactivate()
            models.plan.deactivate(forecast: true)
            models.mode.deactivate()
            models.sources.deactivate(node)
            home.prices.deactivate()
            if node == .car { models.carEnergy.deactivate() }
            if node == .home { home.savings.deactivate() }
            trace.stopSound()
        }
        .onChange(of: timebase) { _, now in
            UserDefaults.standard.set(now.rawValue, forKey: Timebase.key(node))
            scrub.lift()
        }
        .onChange(of: scrub.isDown) { _, down in
            if down { trace.hold(atMs: Date().timeIntervalSince1970 * 1000) } else { trace.release() }
        }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode, plan: models.planShare)
        }
        .fullScreenCover(isPresented: $enlarged) {
            ChartFullScreen(site: site, node: node, home: home, timebase: $timebase, series: $series, timebases: timebases)
                .navigationTransition(.zoom(sourceID: "chart", in: chartZoom))
        }
        #if DEBUG
        // `-FTWEnlarge YES` opens the chart on the whole screen, for
        // screenshots.
        .task {
            guard UserDefaults.standard.bool(forKey: "FTWEnlarge") else { return }
            try? await Task.sleep(for: .seconds(1))
            enlarged = true
        }
        #endif
    }

    private var timebases: [Timebase] { Timebase.allCases.filter { $0 != .ahead || hasAhead } }

    /// `chartMax` is half the screen's height on the fixed page, nil where
    /// the page scrolls. On the fixed page the chart takes the height the
    /// rest leaves, from 200 pt up to `chartMax`; what is left after that
    /// sits between the chart and the picker, never at the foot.
    private func page(chartMax: CGFloat?) -> some View {
        let fill = chartMax != nil
        let chips = timebase == .today || timebase == .twoDays
        return VStack(alignment: .leading, spacing: 0) {
            NodeHero(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, text: text)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
            // The series a history shows; the row keeps its room on every
            // timebase, so nothing moves on a switch.
            SeriesChips(own: node, available: Self.chartable(node), chosen: $series)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .opacity(chips ? 1 : 0)
                .allowsHitTesting(chips)
                .accessibilityHidden(!chips)
                .fixedSize(horizontal: false, vertical: true)
            // A tap opens it on the whole screen, growing out of this one.
            // The chart's own overlay tells a tap from a scrub.
            NodeChart(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, series: series, text: text, onTap: { enlarged = true })
                .frame(minHeight: 200, idealHeight: 200, maxHeight: chartMax ?? 200)
                .padding(.horizontal, 4)
                .overlay(alignment: .topTrailing) {
                    EnlargeButton(scrub: scrub) { enlarged = true }
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
                .matchedTransitionSource(id: "chart", in: chartZoom)
                .layoutPriority(1)
            if fill { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 0) {
                Picker(L("Period"), selection: $timebase.animation(.easeInOut(duration: 0.2))) {
                    ForEach(timebases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("node.period")
                .padding(.horizontal, 20)
                .padding(.top, 12)
                RangeLine(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, text: text)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                if node == .battery {
                    ModeRow(mode: models.mode, choose: { choosingMode = true })
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                } else if node == .car {
                    CarRow(home: home, zoom: zoom)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                } else if node == .home {
                    SavingsRow(home: home, zoom: zoom)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                } else if node == .grid, let phases = site.gridPhases {
                    GridPhasesRow(phases: phases)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                NodeFooter(site: site, node: node, live: models.live, titleSaysAge: !site.isLive)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 640, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// The series a node's history can show: the box's tiles, and the car
    /// on its own view, from its hours.
    static func chartable(_ node: EnergyNode) -> [EnergyNode] {
        EnergyNode.allCases.filter { $0 != .car || node == .car }
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
    /// breaks. `plot` gives the plot's size for a scale, since the right
    /// gutter holds the scale's widest label: the trace is built for the
    /// scale on screen, and again when the new scale needs another width.
    /// The scale comes from the window's own readings; a node other than
    /// the home rests below `Flow.idleW`.
    func build(_ samples: [LiveSample], node: EnergyNode, gapMs: Double, plot: (YDomain?) -> CGSize) {
        let previous = frame?.series.domain
        var size = plot(previous)
        guard size.width > 0, size.height > 0 else { return }
        let now = Date()
        func make(_ size: CGSize) -> LiveSeries {
            LiveSeries.build(
                samples,
                sourceGapMs: gapMs,
                windowMs: LiveTrace.windowMs,
                nowMs: now.timeIntervalSince1970 * 1000,
                size: size,
                previous: previous,
                restW: node == .home ? 0 : Flow.idleW
            )
        }
        var built = make(size)
        if plot(built.domain) != size {
            size = plot(built.domain)
            built = make(size)
        }
        // A new height starts over; a new width keeps the slide, which
        // works in time and watts.
        let resized = size.height != self.size.height
        self.size = size
        let series = built
        frame = resized ? TraceFrame(series: series, previous: nil, arrivedAt: now) : TraceFrame(series: series, after: frame, arrivedAt: now)
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
/// node's second fact on the right. The figure steps as Now's does
/// (`Flow.quantised`), so it rolls only when its digits change. Under a
/// finger on the live trace it gives the exact reading there and its time,
/// and comes back with the spring. The word keeps one size and one line in
/// every state, so nothing under the hero moves. The car view opens on it
/// too.
struct NodeHero: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let trace: NodeTraceModel
    let scrub: ScrubModel
    let timebase: NodeView.Timebase
    let text: PeriodText
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
        // Under a finger the hero says what the finger is on, on Live and
        // on the measured past alike. The hours ahead are a plan, not a
        // reading, so there the hero stays on now.
        let under: (watts: Double?, signed: Double, word: String)? = switch timebase {
        case .live: fingered.map { ($0.watts, $0.signed, $0.word) }
        case .today, .twoDays: text.hero(scrub).map { ($0.watts, $0.signed, $0.word) }
        case .ahead: nil
        }
        let watts = under.map(\.watts) ?? reading?.watts.map(Flow.quantised)
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
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            SecondFact(site: site, node: node, home: home, reading: reading, live: live)
        }
        .transaction { $0.animation = scrub.isDown ? nil : Theme.spring }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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
            return (abs(mean), mean, NodeLive.spanWords(fromMs: slice.first!.t, toMs: slice.last!.t, meanW: mean, zone: .current))
        }
        return nil
    }
}

/// The fact beside the figure that only this node has: the battery's level
/// as a ring, the car's level as a ring with its goal and where the level
/// comes from, what the grid costs an hour, the sun against its forecast,
/// or the home's sources.
struct SecondFact: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let reading: NodeReading?
    let live: Bool
    /// The level's ring, beside the hero's figure.
    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 84

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch node {
            case .battery:
                if let pct = reading?.levelPct {
                    levelRing(pct, text: AppWords.percent(pct), tint: reading.map(NodeLook.hue) ?? Theme.stores, lit: live, glows: true, goal: nil)
                }
            case .car:
                // Never worked out from power: the level as the car, this
                // phone or the box last gave it, with where from and how old.
                // On a box that keeps cars, the car's own, plugged in or not;
                // none for a plugged-in car the box cannot name.
                if home.cars.keepsCars, let car = home.cars.shownCar, let level = home.cars.level(car) {
                    let goal = car.goal.map { CarsModel.schedule($0, nowMs: site.minuteMs, zone: home.loadpoints.zone) }
                    levelRing(level.pct, text: CarText.percent(level), tint: Theme.car, lit: !level.guessed, glows: false, goal: goal.flatMap(Self.goalPct))
                    Text(CarText.origin(level, nowMs: site.minuteMs, zone: home.loadpoints.zone))
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                } else if let level = home.loadpoints.carLevel {
                    let guessed = level.origin == .assumed || level.origin == .unconfirmed
                    let lp = home.loadpoints.points.first(where: \.pluggedIn) ?? home.loadpoints.points.first
                    levelRing(level.pct, text: (guessed ? "≈\u{00A0}" : "") + AppWords.percent(level.pct), tint: Theme.car, lit: !guessed, glows: false, goal: lp?.schedule.flatMap(Self.goalPct))
                    Text(EVText.originAged(level, nowMs: site.minuteMs, zone: home.loadpoints.zone))
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
                // This hour against its forecast while the sun is up, and
                // what the rest of today should bring under it; while the
                // sun is down, when it comes back.
                let plan = home.nodes.plan
                let made = reading?.watts ?? 0
                let forecast = plan.forecastAhead(nowMs: site.nowMs).first { $0.startMs <= site.nowMs && site.nowMs < $0.startMs + $0.durationMs }?.pvW
                let share = NodeLive.solarShare(madeW: made, forecastW: forecast)
                let outlook = NodeLive.solarOutlook(plan.forecast, nowMs: site.minuteMs, zone: .current)
                if let first = share ?? outlook {
                    Text(first)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
                if share != nil, let outlook {
                    Text(outlook)
                        .font(.footnote)
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

extension SecondFact {
    /// The level in its ring, the figure in the middle: what the cell
    /// meter and the large figure said, in the ring's language.
    func levelRing(_ pct: Double, text: String, tint: Color, lit: Bool, glows: Bool, goal: Double?) -> some View {
        LevelRing(pct: pct, goalPct: goal, tint: tint, lit: lit, glows: glows, thickness: max(5, ringSize * 0.07)) {
            Text(text)
                .font(Theme.figure(ringSize * 0.26))
                .foregroundStyle(lit ? Theme.ink : Theme.ink3)
                .contentTransition(.numericText(value: pct))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, ringSize * 0.12)
        }
        .frame(width: ringSize, height: ringSize)
    }

    /// The goal's level, unless the goal is the car's own limit.
    static func goalPct(_ s: Loadpoint.Schedule) -> Double? {
        s.finishAtVehicleLimit ? nil : s.socPct
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

/// The way to the chart on the whole screen, in the plot's top right
/// corner, in the band the scrub tag uses and clear of the axis labels in
/// the gutter beside it. It steps aside while a finger is on the chart, so
/// the tag can read.
private struct EnlargeButton: View {
    let scrub: ScrubModel
    let action: () -> Void
    /// The charts' axis size; the widest gutter, Ahead's, is 3.8 of it.
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink3)
                .frame(width: 44, height: 20, alignment: .trailing)
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4 + axis * 3.8)
        .opacity(scrub.isDown ? 0 : 1)
        .allowsHitTesting(!scrub.isDown)
        .animation(.easeOut(duration: 0.15), value: scrub.isDown)
        .accessibilityLabel(L("Enlarge the chart"))
        .accessibilityIdentifier("node.chart.enlarge")
    }
}

/// One place for the node's chart. Live streams the trace; today and the
/// last two days draw the chosen series on the engine; the hours ahead
/// draw the plan or the forecast with the price. A switch cross-fades in
/// 0.2 s and the scale does not morph.
private struct NodeChart: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let trace: NodeTraceModel
    let scrub: ScrubModel
    let timebase: NodeView.Timebase
    let series: [EnergyNode]
    let text: PeriodText
    /// A tap that never became a scrub; nil on the whole screen.
    var onTap: (() -> Void)?

    var body: some View {
        ZStack {
            switch timebase {
            case .live:
                LiveChartArea(site: site, node: node, live: home.nodes.live, trace: trace, scrub: scrub, onTap: onTap)
                    .transition(.opacity)
            case .today, .twoDays:
                HistoryChartArea(site: site, node: node, home: home, scrub: scrub, period: timebase, series: series, text: text, onTap: onTap)
                    .transition(.opacity)
                    .accessibilityIdentifier("node.period.chart")
            case .ahead:
                AheadChartArea(site: site, node: node, home: home, scrub: scrub, text: text, onTap: onTap)
                    .transition(.opacity)
                    .accessibilityIdentifier("node.period.chart")
            }
        }
        // A chart's words stop growing at xxLarge: they are drawn in the
        // Canvas, and said again under the chart and to VoiceOver. Set here,
        // above the charts, so their scaled sizes read it.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The chart on the whole screen, grown out of the small one: the same
/// timebases, series and finger, with room to read. It closes as every
/// sheet does, with the system's close button.
private struct ChartFullScreen: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    @Binding var timebase: NodeView.Timebase
    @Binding var series: [EnergyNode]
    let timebases: [NodeView.Timebase]
    @State private var scrub = ScrubModel()
    @State private var trace = NodeTraceModel()
    @State private var text = PeriodText()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Group {
                // The accessibility sizes scroll, with the chart at a fixed
                // height; every other size is one page.
                if typeSize.isAccessibilitySize {
                    ScrollView { content(chart: 360) }
                } else {
                    content(chart: nil)
                }
            }
            .background(Theme.ground)
            .navigationTitle(node.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("node.chart.close")
                }
            }
        }
        .onChange(of: timebase) { _, _ in scrub.lift() }
        .onChange(of: scrub.isDown) { _, down in
            if down { trace.hold(atMs: Date().timeIntervalSince1970 * 1000) } else { trace.release() }
        }
    }

    private func content(chart height: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NodeHero(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, text: text)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.horizontal, 20)
            SeriesChips(own: node, available: NodeView.chartable(node), chosen: $series)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .opacity(timebase == .today || timebase == .twoDays ? 1 : 0)
                .allowsHitTesting(timebase == .today || timebase == .twoDays)
            NodeChart(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, series: series, text: text)
                .frame(height: height)
                .frame(maxHeight: height == nil ? .infinity : nil)
                .padding(.horizontal, 4)
            Picker(L("Period"), selection: $timebase.animation(.easeInOut(duration: 0.2))) {
                ForEach(timebases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("node.chart.period")
            .padding(.horizontal, 20)
            .padding(.top, 12)
            RangeLine(site: site, node: node, home: home, trace: trace, scrub: scrub, timebase: timebase, text: text)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            // No status line over the whole screen: the footer gives this
            // node's age whenever it is not live.
            NodeFooter(site: site, node: node, live: home.nodes.live, titleSaysAge: false)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
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
    var onTap: (() -> Void)?
    @State private var size: CGSize = .zero
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    /// The frame for a scale: the right gutter holds its widest label.
    private func chartFrame(_ domain: YDomain?) -> ChartFrame {
        ChartFrame(top: tag * 1.35 + 8, bottom: 6, trailing: ChartAxes.gutter(domain, axis: axis))
    }

    var body: some View {
        let revision = live.revision
        // The frame the trace on screen was built for.
        let drawn = chartFrame(trace.shown?.series.domain)
        // The same colours as every other chart of this node.
        let look = NodeChartLook.look(node)
        let isLive = site.freshness(node).live
        ZStack {
            // Takes the whole frame before the first reading, so the
            // geometry knows its size.
            Color.clear
            if let frame = trace.shown {
                LiveTraceSurface(frame: frame, look: look, live: isLive, chartFrame: drawn, frozenAtMs: trace.frozenAtMs, catchUp: trace.catchUp, axisSize: axis)
                LiveScrubOverlay(
                    frame: frame,
                    chartFrame: drawn,
                    model: scrub,
                    viewMs: trace.frozenAtMs ?? Date().timeIntervalSince1970 * 1000,
                    look: look,
                    tagSize: tag,
                    tag: { NodeLive.tag($0.t, watts: $0.v) },
                    spanTag: { r in
                        let slice = frame.readings[r]
                        let mean = slice.map(\.v).reduce(0, +) / Double(max(1, slice.count))
                        return Readouts.seconds(slice.first!.t) + "–" + Readouts.seconds(slice.last!.t) + "  " + NodeWords.format("avg %@", AppWords.power(abs(mean)))
                    },
                    onTap: onTap
                )
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: revision, initial: true) { rebuild() }
        .onChange(of: size) { rebuild() }
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

    private func rebuild() {
        let size = size
        #if DEBUG
        let began = ContinuousClock.now
        defer { TraceCost.log.debug("trace built in \((ContinuousClock.now - began) / .microseconds(1), format: .fixed(precision: 0)) µs") }
        #endif
        trace.build(live.samples(node, sinceMs: Date().timeIntervalSince1970 * 1000 - LiveTrace.windowMs - 10_000), node: node, gapMs: site.readingGapMs) { chartFrame($0).plot(in: size).size }
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
    let text: PeriodText

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: "\n")
            Text(line)
                .accessibilityIdentifier("chart.readout")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink2)
        .lineLimit(typeSize.isAccessibilitySize ? 5 : 2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    private var line: String {
        guard timebase == .live else {
            if let under = text.text(scrub) { return under }
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

/// `VIA RELAY · SUNGROW · READS EVERY 1 S`: how the reading reaches the
/// phone, the device behind it, and how often the device itself reads,
/// from its readings. When this node is not live and the title does not
/// already give an age, it starts `○ AS OF 14:05`. One line, so the
/// controls over it never move.
private struct NodeFooter: View {
    let site: SiteModel
    let node: EnergyNode
    let live: LiveTrace
    let titleSaysAge: Bool
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10

    var body: some View {
        let points = live.points(node.fid, sinceMs: site.nowMs - LiveTrace.windowMs)
        // A value that never changed in the window says nothing of how often
        // the device reads, so the footer does not guess.
        let period = LiveSeries.period(of: points.map { LiveSample(t: $0.t, v: $0.v) })
        let text = NodeLive.footer(node, site.freshness(node), carrier: site.carrier, periodMs: period, titleSaysAge: titleSaysAge, nowMs: site.minuteMs, zone: .current)
        // A long line shrinks to fit, but its row keeps the full size's
        // height, so nothing over it moves when the cadence joins it.
        ZStack(alignment: .leading) {
            Text(verbatim: " ")
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
                .animation(.default, value: text)
                .accessibilityIdentifier("node.footer")
        }
        .font(.system(size: size, design: .monospaced))
        .tracking(0.5)
        .foregroundStyle(Theme.ink3)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The battery's one extra row: `Mode · Balanced`, with the chevrons of a
/// row that opens a sheet.
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
                    // It opens a sheet, not a page.
                    Image(systemName: "chevron.up.chevron.down")
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

/// The car's one extra row: what it does now, into the car view. On a box
/// that keeps cars, a row per car, the one on a charger first, each with
/// its level, and "Which car?" while a charger asks.
private struct CarRow: View {
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        let cars = home.cars
        let loadpoints = home.loadpoints
        if cars.keepsCars, !cars.cars.isEmpty || !cars.asking.isEmpty || !cars.visitors.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let asking = cars.asking.first {
                    row(.car(asking.id), id: "node.car.which") {
                        Text(C("Which car?")).foregroundStyle(Theme.ink)
                        Text(verbatim: "·").foregroundStyle(Theme.ink3)
                        Text(CarText.chargerName(asking)).foregroundStyle(Theme.ink2)
                    }
                }
                // A visitor's charger, or one whose car the box no longer
                // asks about: still a way into its controls.
                ForEach(cars.visitors) { lp in
                    row(.car(lp.id), id: "node.car.visitor") {
                        Text(C("A visitor's car")).foregroundStyle(Theme.ink)
                        Text(verbatim: "·").foregroundStyle(Theme.ink3)
                        Text(EVText.status(lp, zone: loadpoints.zone)).foregroundStyle(Theme.ink2)
                    }
                }
                ForEach(cars.ordered.prefix(cars.asking.isEmpty && cars.visitors.isEmpty ? 2 : 1)) { car in
                    row(.car(car.id), id: "node.car.open") {
                        Text(car.shownName).foregroundStyle(Theme.ink)
                        if let level = cars.level(car) {
                            Text(verbatim: "·").foregroundStyle(Theme.ink3)
                            Text(CarText.percent(level)).foregroundStyle(level.guessed ? Theme.ink3 : Theme.ink).monospacedDigit()
                        }
                        Text(verbatim: "·").foregroundStyle(Theme.ink3)
                        Text(cars.charger(of: car).map { EVText.status($0, zone: loadpoints.zone) } ?? C("Not plugged in")).foregroundStyle(Theme.ink2)
                    }
                }
            }
        } else if let lp = loadpoints.points.first {
            row(.car(lp.id), id: "node.car.open") {
                Text(EVText.status(lp, zone: loadpoints.zone)).foregroundStyle(Theme.ink)
            }
        }
    }

    private func row<Label: View>(_ route: HomeRoute, id: String, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 6) {
                label()
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
        .matchedTransitionSource(id: route, in: zoom)
        .accessibilityIdentifier(id)
    }
}

/// The home's one extra row: what it saved today, into the savings view.
/// The row is there before the box answers, so nothing moves when it does.
private struct SavingsRow: View {
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        NavigationLink(value: HomeRoute.savings) {
            HStack(spacing: 6) {
                Text(L("Savings")).foregroundStyle(Theme.ink2)
                if let today = SavingsGlance.row(home.savings.week, nowMs: home.site.minuteMs, currency: home.prices.currency) {
                    Text(verbatim: "·").foregroundStyle(Theme.ink3)
                    Text(today)
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
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
        .matchedTransitionSource(id: HomeRoute.savings, in: zoom)
        .animation(Theme.spring, value: home.savings.week?.value)
        .accessibilityIdentifier("node.savings.open")
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
            let energy = NodeSummary.energy(node, e, today: period == .today)
            // FTW Cloud's copy while the box is away: dated, on a line of
            // its own, first, so a long line cuts the sum and never the date.
            guard let cloud = models.history.cloudNote(nowMs: site.minuteMs, zone: zone) else { return energy }
            return cloud + "\n" + energy
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
