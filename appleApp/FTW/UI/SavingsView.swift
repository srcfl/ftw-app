import Accessibility
import FTWKit
import SwiftUI

/// What the home saved, as the box counted it: the money saved against a
/// home with no solar and no battery as the hero, a bar per day, and Day ·
/// Week · Month in the thumb's reach. A finger on a bar gives the hero that
/// day, and the two lines under the chart what it cost. One screen, no
/// cards. Every figure is the box's; the app adds nothing up.
///
/// It opens on the last answer, dated, and asks the box only when the
/// quarter hour has moved on.
struct SavingsView: View {
    let home: HomeModels
    @State private var scrub = ScrubModel()
    @State private var period: Savings.Period = SavingsView.remembered
    @Environment(\.dynamicTypeSize) private var typeSize

    static let key = "ftw.savings.period"

    /// The last choice on this phone; debug builds take
    /// `-FTWSavingsPeriod month` and the like, for screenshots.
    static var remembered: Savings.Period {
        #if DEBUG
        if let asked = UserDefaults.standard.string(forKey: "FTWSavingsPeriod").flatMap(Savings.Period.init(rawValue:)) { return asked }
        #endif
        return UserDefaults.standard.string(forKey: key).flatMap(Savings.Period.init(rawValue:)) ?? .day
    }

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
        .navigationTitle(L("Savings"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            home.savings.activate(month: true)
            LaunchClock.mark("first content")
        }
        .onDisappear { home.savings.deactivate(month: true) }
        .onChange(of: period) { _, now in
            UserDefaults.standard.set(now.rawValue, forKey: Self.key)
            scrub.lift()
        }
    }

    private func page(fill: Bool) -> some View {
        SavingsBody(site: home.site, savings: home.savings, prices: home.prices, period: $period, scrub: scrub, fill: fill)
            .padding(.top, 8)
            .frame(maxWidth: 640, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .frame(maxWidth: .infinity)
    }
}

/// Reads the minute, the answers and the currency, and hands them on as
/// one value, so the page below redraws when what it says changes.
private struct SavingsBody: View {
    let site: SiteModel
    let savings: SavingsModel
    let prices: PriceModel
    @Binding var period: Savings.Period
    let scrub: ScrubModel
    let fill: Bool

    var body: some View {
        let answer = period == .month ? savings.month : savings.week
        let glance = SavingsGlance.make(period: period, answer: answer, problem: savings.problem, nowMs: site.minuteMs, currency: prices.currency)
        SavingsPage(glance: glance, scrub: scrub, period: $period, fill: fill)
            .equatable()
    }
}

private struct SavingsPage: View, Equatable {
    let glance: SavingsGlance
    let scrub: ScrubModel
    @Binding var period: Savings.Period
    let fill: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.glance == b.glance && a.fill == b.fill && a.scrub === b.scrub
    }

    var body: some View {
        let hidden: RedactionReasons = glance.placeholder ? .placeholder : []
        VStack(alignment: .leading, spacing: 0) {
            SavingsHero(glance: glance, scrub: scrub)
                .redacted(reason: hidden)
                .padding(.horizontal, 20)
            SavingsBarsChart(chart: glance.chart, scrub: scrub)
                .redacted(reason: hidden)
                .frame(minHeight: fill ? 170 : 220, idealHeight: 260, maxHeight: 340)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            Picker(L("Period"), selection: $period.animation(.easeInOut(duration: 0.2))) {
                ForEach(Savings.Period.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("savings.period")
            .padding(.horizontal, 20)
            .padding(.top, 12)
            SavingsReadout(glance: glance, scrub: scrub)
                .redacted(reason: hidden)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            if fill { Spacer(minLength: 8) }
            SavingsFooter(text: glance.footer)
                .padding(.horizontal, 20)
                .padding(.top, fill ? 0 : 16)
                .padding(.bottom, 8)
        }
    }
}

/// "18,40 kr", and under it "Saved today so far". Under a finger it gives
/// way to that day with no animation; on lift it comes back with the
/// spring. "PARTIAL" sits beside the words when the box had prices for
/// less of the time than counts as whole.
private struct SavingsHero: View {
    let glance: SavingsGlance
    let scrub: ScrubModel
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 60
    @ScaledMetric(relativeTo: .title2) private var unit: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var kicker: CGFloat = 11

    var body: some View {
        let r = scrub.index.flatMap { glance.chart.readings.indices.contains($0) ? glance.chart.readings[$0] : nil } ?? glance.reading
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(r.figure)
                    .font(Theme.figure(figureSize))
                    .tracking(-1)
                    .foregroundStyle(r.known ? Theme.ink : Theme.ink3)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Text(r.unit)
                    .font(.system(size: unit, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.word)
                    .font(.headline)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let k = r.kicker {
                    Text(k)
                        .font(.system(size: kicker, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = scrub.isDown ? nil : Theme.spring }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("savings.hero")
    }
}

/// Two reserved lines under the picker: what the period cost against a
/// home with no solar or battery, and what was bought and sold, or under a
/// finger the same for that day. The page never moves.
private struct SavingsReadout: View {
    let glance: SavingsGlance
    let scrub: ScrubModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let r = scrub.index.flatMap { glance.chart.readings.indices.contains($0) ? glance.chart.readings[$0] : nil } ?? glance.reading
        ZStack(alignment: .topLeading) {
            Text(verbatim: "\n")
            Text(r.lines.joined(separator: "\n"))
                .accessibilityIdentifier("savings.readout")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink2)
        .lineLimit(reserved, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    /// Two lines at the standard size. Each line wraps at the larger
    /// sizes, so more are held open there, and nothing is cut.
    private var reserved: Int {
        if typeSize.isAccessibilitySize { return 6 }
        if typeSize >= .xxLarge { return 4 }
        return typeSize >= .xLarge ? 3 : 2
    }
}

/// `AS OF 14:32`, or `SAVED ON THIS PHONE · AS OF TUE 23:10`.
private struct SavingsFooter: View {
    let text: String
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.ink3)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .contentTransition(.opacity)
            .accessibilityIdentifier("savings.footer")
    }
}

// MARK: - The bars

/// The surface and the finger's overlay on the same frame. Mono labels are
/// sized with the text and stop growing at accessibility1.
private struct SavingsBarsChart: View {
    let chart: SavingsChart
    let scrub: ScrubModel
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    var body: some View {
        let frame = SavingsBarsDrawing.frame(axis: axis, tag: tag)
        ZStack {
            ChartSurface(drawing: SavingsBarsDrawing(chart: chart, frame: frame, axis: axis))
                .equatable()
            if !chart.isEmpty {
                ScrubOverlay(
                    track: ScrubTrack(grid: chart.grid, domain: chart.domain, values: chart.values, tags: chart.tags, landmarks: chart.landmarks,
                                      bars: true, barShare: SavingsBarsDrawing.share(chart.count), barRadius: SavingsBarsDrawing.radius),
                    frame: frame,
                    model: scrub,
                    tagSize: tag,
                    spanTag: { r in AppWords.format("%@ DAYS", String(r.count)) }
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Savings by day"))
        .accessibilityChartDescriptor(SavingsDescriptor(chart: chart))
        .accessibilityIdentifier("savings.chart")
    }
}

/// A bar per day in ink: a saving above zero, a day that cost more below
/// it. Today, still filling, is hatched: on its way. A day the box priced
/// only in part is fainter; a day it had no price for is a dotted stub on
/// zero. In the Day view the day stands in full ink and the week behind it
/// dims. The top of the scale sits in the right gutter, the days under the
/// plot.
struct SavingsBarsDrawing: ChartDrawing {
    let chart: SavingsChart
    let frame: ChartFrame
    var axis: CGFloat = 10

    /// Rounded away from zero: never angular.
    static let radius: CGFloat = 3

    /// A week's bars stand apart with air between them; a month's are
    /// narrower and fill more of their day.
    static func share(_ count: Int) -> CGFloat { count <= 7 ? 0.56 : 0.7 }

    static func frame(axis: CGFloat, tag: CGFloat) -> ChartFrame {
        ChartFrame(top: tag * 1.35 + 8, bottom: 8 + axis * 1.35, trailing: axis * 4.4)
    }

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let map = YMap(domain: chart.domain, height: plot.height)
        let base = plot.minY + snap(map.baseline)
        let grid = chart.grid
        let share = Self.share(chart.count)

        // The top of the scale, and the bottom when a day cost more: a
        // dotted rule and its figure in the gutter.
        for (y, text) in [(plot.minY, chart.top), (plot.maxY, chart.bottom ?? "")] where !text.isEmpty {
            var rule = Path()
            rule.move(to: CGPoint(x: plot.minX, y: snap(y) + px / 2))
            rule.addLine(to: CGPoint(x: plot.maxX, y: snap(y) + px / 2))
            g.stroke(rule, with: .color(Theme.ink.opacity(0.25)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            g.draw(g.resolve(ChartText.label(text, size: axis)), at: CGPoint(x: plot.maxX + 4, y: y), anchor: .leading)
        }

        var zero = Path()
        zero.move(to: CGPoint(x: plot.minX, y: base + px / 2))
        zero.addLine(to: CGPoint(x: plot.maxX, y: base + px / 2))
        g.stroke(zero, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))

        for i in 0..<chart.count {
            let a0 = snap(plot.minX + grid.x(atMs: grid.startMs(i), width: plot.width))
            let b0 = snap(plot.minX + grid.x(atMs: grid.endMs(i), width: plot.width)) - px
            let inset = snap((b0 - a0) * (1 - share) / 2)
            let a = a0 + inset, b = b0 - inset
            guard let v = chart.values[i] else {
                // The box had no price: it confirms no money that day.
                var stub = Path()
                stub.move(to: CGPoint(x: a, y: base - px))
                stub.addLine(to: CGPoint(x: b, y: base - px))
                g.stroke(stub, with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: px * 2, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
                continue
            }
            let y = plot.minY + snap(map.y(v))
            let rect = CGRect(x: a, y: min(y, base), width: max(px, b - a), height: max(px, abs(y - base)))
            let r = min(Self.radius, rect.width / 2, rect.height)
            let radii = v >= 0
                ? RectangleCornerRadii(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
                : RectangleCornerRadii(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
            let bar = Path(roundedRect: rect, cornerRadii: radii, style: .continuous)
            let filling = i == chart.today
            let alpha: Double
            if let focus = chart.focus {
                alpha = i == focus ? 1 : 0.2
            } else {
                alpha = filling || chart.partial.contains(i) ? 0.3 : 0.55
            }
            g.fill(bar, with: .color(Theme.ink.opacity(alpha)))
            if filling {
                var hatch = g
                hatch.clip(to: bar)
                var lines = Path()
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    lines.move(to: CGPoint(x: x, y: rect.maxY))
                    lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += 4
                }
                let ink = i == chart.focus ? Theme.ground.opacity(0.45) : Theme.ink.opacity(0.5)
                hatch.stroke(lines, with: .color(ink), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
            }
        }

        // TODAY first, then each day that has room.
        var taken: [ClosedRange<CGFloat>] = []
        for label in chart.labels.sorted(by: { $0.first && !$1.first }) {
            let text = g.resolve(ChartText.label(label.text, size: axis, weight: label.first ? .semibold : .regular, color: label.first ? Theme.ink2 : Theme.ink3))
            let w = text.measure(in: size).width
            let x = plot.minX + grid.midX(label.index, width: plot.width)
            let left = min(max(plot.minX, x - w / 2), max(plot.minX, plot.maxX - w))
            let span = (left - 4)...(left + w + 4)
            guard !taken.contains(where: { $0.overlaps(span) }) else { continue }
            taken.append(span)
            g.draw(text, at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        }
    }
}

/// The days as VoiceOver reads them: a day a step, with its tag.
struct SavingsDescriptor: AXChartDescriptorRepresentable {
    let chart: SavingsChart

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = chart.values.compactMap { $0 }.map { $0 / 100 }
        let lo = min(0, values.min() ?? 0), hi = max(lo + 1, values.max() ?? 1)
        let x = AXCategoricalDataAxisDescriptor(title: L("Day"), categoryOrder: chart.tags)
        let y = AXNumericDataAxisDescriptor(title: L("Savings"), range: lo...hi, gridlinePositions: []) { AppWords.decimal(PowerFormat.fixed($0, 2)) }
        let points = chart.values.indices.compactMap { i in
            chart.values[i].map { AXDataPoint(x: chart.tags[i], y: $0 / 100, additionalValues: [], label: chart.readings.indices.contains(i) ? chart.readings[i].lines.first : nil) }
        }
        let series = AXDataSeriesDescriptor(name: L("Savings"), isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: L("Savings by day"), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
