import FTWKit
import SwiftUI

/// The price: what power costs now as the hero, the next 24 hours as a bar
/// per slot, and what the plan does in each. A finger on the bars gives
/// the hero the slot's price and time, and the lines under the chart what
/// the plan does then. Under them one mono line says what the plan does at
/// these prices. One screen, no cards. The chart takes a little over half
/// the screen's height, or what the rest leaves, never under 240 pt; what
/// is left sits between the chart and the lines under it, never at the
/// foot.
struct PriceView: View {
    let home: HomeModels
    /// The day History's row asked for, midnight to midnight; nil opens
    /// where now is, as the plan and the widget open it.
    var dayMs: Double?
    @State private var scrub = ScrubModel()
    /// The window a finger left. Nil leaves the chart where it opened.
    @State private var window: TimelineWindow?
    /// The window one move started from, so every event of it transforms
    /// that window rather than the last one it made.
    @State private var panBase: TimelineWindow?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var clock: ZoneClock { .of(.current) }

    private var opened: TimelineWindow? {
        dayMs.map { TimelineWindow.day(ofMs: $0, nowMs: home.site.nowMs, clock: clock) }
    }

    /// The window drawn, carried along with now while now is in it.
    private var shown: TimelineWindow? {
        (window ?? opened)?.following(nowMs: home.site.nowMs, clock: clock)
    }

    var body: some View {
        Group {
            // The accessibility sizes scroll; every other size is one fixed
            // page. Chosen by the size, never by a fit, so the page never
            // swaps branches under a finger.
            if typeSize.isAccessibilitySize {
                ScrollView { page(chartMax: nil) }
            } else {
                // 0.55 of the screen: at half, a Pro Max kept 129 pt of ground
                // between the chart and its lines.
                GeometryReader { geo in
                    page(chartMax: (geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom) * 0.55)
                }
            }
        }
        .background(Theme.ground)
        .navigationTitle(L("Electricity price"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The way back, as a node's timeline has it: there only once
            // the chart has been moved off today.
            if shown?.isToday == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(Theme.spring) { window = .today(nowMs: home.site.nowMs, clock: clock) }
                    } label: {
                        Label(L("Today"), systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("price.today")
                }
            }
        }
        .onAppear {
            home.prices.activate()
            // The days behind, for a chart dragged back off today.
            home.prices.activatePast()
            home.nodes.plan.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            home.prices.deactivate()
            home.prices.deactivatePast()
            home.nodes.plan.deactivate()
        }
    }

    /// `chartMax` is the chart's most on the fixed page, nil where the page
    /// scrolls.
    private func page(chartMax: CGFloat?) -> some View {
        PriceBody(site: home.site, prices: home.prices, plan: home.nodes.planShare, scrub: scrub, chartMax: chartMax,
                  window: shown, onPan: pan, onPanEnded: { panBase = nil })
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: 640, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: chartMax == nil ? nil : .infinity, alignment: .top)
    }

    /// A finger moving the chart through time. `drawn` is the window the
    /// chart had when the finger landed, so a chart that opened where now
    /// is does not jump as the move begins.
    private func pan(anchor: Double, destination: Double, began: Bool, drawn: TimelineWindow) {
        let nowMs = home.site.nowMs
        if began || panBase == nil { panBase = drawn }
        window = (panBase ?? drawn).transformed(anchor: anchor, destination: destination, magnification: 1, nowMs: nowMs)
    }
}

/// Reads the minute, the prices and the plan, and hands them on as values,
/// so the page below redraws once a minute at most.
private struct PriceBody: View {
    let site: SiteModel
    let prices: PriceModel
    let plan: PlanShare
    let scrub: ScrubModel
    let chartMax: CGFloat?
    /// The window drawn, or nil to start at the slot now is in.
    let window: TimelineWindow?
    let onPan: (Double, Double, Bool, TimelineWindow) -> Void
    let onPanEnded: () -> Void

    var body: some View {
        if let held = prices.prices {
            // Every slot the phone holds in the window: the days behind
            // and the days ahead as one series, with a slot either side so
            // the first and last bars are whole.
            let from = (window?.fromMs ?? site.nowMs) - 3_600_000
            let to = (window?.toMs ?? site.nowMs + 24 * 3_600_000) + 3_600_000
            PricePage(slots: prices.slots(fromMs: from, toMs: to), zone: held.zone, currency: held.currency,
                      window: window, minuteMs: site.minuteMs, plan: plan.entry, problem: prices.pastProblem,
                      scrub: scrub, chartMax: chartMax, onPan: onPan, onPanEnded: onPanEnded)
                .equatable()
        } else {
            Text(L("Reading the prices from your box…"))
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PricePage: View, Equatable {
    let slots: [PriceSlot]
    let zone: String
    let currency: String
    let window: TimelineWindow?
    let minuteMs: Double
    let plan: PlanEntry?
    /// Why the days behind are missing, where the wire is the reason.
    let problem: String?
    let scrub: ScrubModel
    let chartMax: CGFloat?
    let onPan: (Double, Double, Bool, TimelineWindow) -> Void
    let onPanEnded: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.slots == b.slots && a.zone == b.zone && a.currency == b.currency && a.window == b.window
            && a.minuteMs == b.minuteMs && a.plan == b.plan && a.problem == b.problem && a.chartMax == b.chartMax && a.scrub === b.scrub
    }

    var body: some View {
        // Built once per minute or change of prices, window or plan.
        let clock = ZoneClock.of(.current)
        let chart = PriceChart.build(slots, currency: currency, nowMs: minuteMs, fromMs: window?.fromMs,
                                     spanMs: window?.spanMs ?? 24 * 3_600_000, plan: plan, clock: clock)
        let included = PriceGlance.text(PriceGlance.included(slots))
        // The window as the chart draws it, so a finger takes it from
        // exactly there even before anything has moved it.
        let drawn = window ?? TimelineWindow(fromMs: chart.grid.fromMs, toMs: chart.grid.toMs, nowMs: minuteMs)
        let behind = drawn.toMs <= minuteMs
        VStack(alignment: .leading, spacing: 0) {
            PriceHero(chart: chart, zone: zone, dayName: TimelineLabel.window(drawn, nowMs: minuteMs, clock: clock), scrub: scrub)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .fixedSize(horizontal: false, vertical: true)
            if chart.isEmpty {
                // What the box has, or what stopped it saying: a day it
                // never fetched is empty, and a wire that failed says so.
                Text(behind ? (problem ?? L("No prices for this time.")) : L("No prices ahead yet."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 24)
            } else {
                // What the rest leaves, up to 0.55 of the screen: about
                // 330 pt on an SE, 526 on a Pro Max.
                PriceBarsChart(chart: chart, scrub: scrub, onPan: { a, b, began in onPan(a, b, began, drawn) }, onPanEnded: onPanEnded)
                    .frame(minHeight: 240, idealHeight: 240, maxHeight: chartMax ?? 240)
                    .layoutPriority(1)
                    .padding(.top, 24)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .accessibilityElement()
                    .accessibilityLabel(L("Electricity price"))
                    .accessibilityHint(L("Drag to move through time."))
                    .accessibilityChartDescriptor(PriceDescriptor(chart: chart))
                    .accessibilityIdentifier("price.chart")
                if chartMax != nil { Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 0) {
                    PriceReadout(chart: chart, included: included, planned: plan != nil, scrub: scrub)
                        .padding(.top, 16)
                    PlanAtThesePrices(line: chart.planLine, short: chart.planLineShort)
                        .padding(.top, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if chartMax != nil, chart.isEmpty { Spacer(minLength: 0) }
        }
    }
}

/// "128 öre/kWh", and under it "Now · SE3". Under a finger it gives way to
/// the slot's price and time with no animation; on lift it comes back with
/// the spring.
private struct PriceHero: View {
    let chart: PriceChart
    let zone: String
    /// What the window is called, for a window with no now in it.
    let dayName: String
    let scrub: ScrubModel
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 60
    @ScaledMetric(relativeTo: .title2) private var unit: CGFloat = 22

    var body: some View {
        let i = scrub.index ?? (scrub.span == nil ? chart.nowIndex : nil)
        let spanMean = scrub.span.flatMap(chart.mean)
        // A window behind now has no price "now": at rest it gives that
        // window's own average, and says so.
        let dayMean = i == nil && scrub.span == nil ? chart.meanShown.map { _ in chart.meanText } : nil
        // A slot with no price yet says so in quiet ink, never a figure.
        let priced = spanMean != nil || dayMean != nil || (i.map { chart.minor[$0] != nil } ?? false)
        let figure = spanMean.map(chart.figure) ?? i.map { chart.figure[$0] } ?? dayMean ?? "—"
        let resting = dayMean != nil
            ? NodeWords.format("%@ · average", dayName)
            : (zone.isEmpty ? L("Now") : NodeWords.format("Now · %@", zone))
        let word = scrub.span.map(chart.when) ?? scrub.index.map { chart.when[$0] } ?? resting
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(figure)
                    .font(Theme.figure(figureSize))
                    .tracking(-1)
                    .foregroundStyle(priced ? Theme.ink : Theme.ink3)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Text(chart.unit)
                    .font(.system(size: unit, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(word)
                .font(.headline)
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = scrub.isDown ? nil : Theme.spring }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
    }
}

/// The surface and the finger's overlay on the same frame. Mono labels are
/// sized with the text and stop growing at accessibility1.
private struct PriceBarsChart: View {
    let chart: PriceChart
    let scrub: ScrubModel
    let onPan: (Double, Double, Bool) -> Void
    let onPanEnded: () -> Void
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var kicker: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    var body: some View {
        let frame = PriceBarsDrawing.frame(axis: axis, kicker: kicker, tag: tag, labels: [PriceChart.averageWord, chart.meanText])
        ZStack {
            ChartSurface(drawing: PriceBarsDrawing(chart: chart, frame: frame, axis: axis, kicker: kicker))
                .equatable()
            ScrubOverlay(
                track: ScrubTrack(grid: chart.grid, domain: chart.domain, values: chart.shown, tags: chart.tag, landmarks: chart.landmarks, bars: true),
                frame: frame,
                model: scrub,
                tagSize: tag,
                spanTag: { [chart] r in chart.when(r) + "  " + (chart.mean(r).map { NodeWords.format("avg %@", chart.figure($0)) } ?? "—") },
                onPan: onPan,
                onPanEnded: onPanEnded
            )
        }
    }
}

/// `STORES 09:15–15:30 AT 58–90 · GIVES 17–20 AT 150–176 ÖRE`: what the
/// plan already read does at these prices, in the kickers' mono. Where the
/// line has no room it drops its second part, never ends in "…". Nothing
/// when there is no plan.
private struct PlanAtThesePrices: View {
    let line: String
    let short: String
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10.5

    var body: some View {
        if !line.isEmpty {
            // By place, never by the words: the short form is the whole
            // line when the plan has one part, and two candidates with one
            // id is a precondition failure inside `ViewThatFits`.
            ViewThatFits(in: .horizontal) {
                ForEach(Array([line, short].enumerated()), id: \.offset) { _, form in
                    Text(form)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: min(size, 15), weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .accessibilityIdentifier("price.plan")
        }
    }
}

/// Two reserved lines under the chart: what the price holds, or under a
/// finger what the plan does in that slot. The page never moves.
private struct PriceReadout: View {
    let chart: PriceChart
    let included: String
    let planned: Bool
    let scrub: ScrubModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Two lines held open, so a longer readout pushes nothing.
            Text(verbatim: "\n")
            Text(text)
                .accessibilityIdentifier("chart.readout")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink2)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    private var text: String {
        if let r = scrub.span {
            guard let mean = chart.mean(r) else { return included }
            let average = NodeWords.format("average %@", chart.figure(mean) + " " + chart.unit)
            return mean < 0 ? PriceChart.paidWord + " · " + average : average
        }
        guard let i = scrub.index else { return included }
        let doing = chart.doing[i]
        if !doing.isEmpty { return doing }
        return planned ? L("Nothing planned then") : included
    }
}

/// The prices as VoiceOver reads them: a slot a step.
struct PriceDescriptor: AXChartDescriptorRepresentable {
    let chart: PriceChart

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = chart.shown.compactMap { $0 }
        let lo = min(0, values.min() ?? 0), hi = max(lo + 1, values.max() ?? 1)
        let start = chart.grid.fromMs, end = max(start + 1, chart.grid.toMs)
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: start...end, gridlinePositions: []) { Readouts.clock($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Electricity price"), range: lo...hi, gridlinePositions: []) { "\(AppWords.decimal(PowerFormat.fixed($0, 1))) \(chart.unit)" }
        let points = chart.shown.indices.compactMap { i in
            chart.shown[i].map { AXDataPoint(x: chart.grid.startMs(i), y: $0, additionalValues: [], label: chart.doing[i].isEmpty ? nil : chart.doing[i]) }
        }
        let series = AXDataSeriesDescriptor(name: L("Electricity price"), isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: L("Electricity price"), summary: chart.cheapestText.isEmpty ? nil : chart.cheapestText, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
