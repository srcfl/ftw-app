import FTWKit
import SwiftUI

/// History, the third tab: what the home did today, as the box recorded
/// it. What it saved first, as the savings view's hero; then a row per
/// node with the day's energy in its own words and the shape of the day so
/// far, each a door into that node's day. Dated, never live: the rows read
/// the five-minute tiles the node views draw, and the foot says where they
/// end. Nothing here asks the box on a timer; the tiles come as the node
/// views' do, when the five minutes turn.
struct HistoryTabView: View {
    let home: HomeModels
    let zoom: Namespace.ID
    @State private var visible = false
    @State private var carAsked = false

    private var hasCharger: Bool { !home.loadpoints.points.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HistorySavings(home: home, zoom: zoom)
                    .padding(.bottom, 24)
                Kicker(L("Today"))
                    .padding(.bottom, 2)
                DayRows(home: home, zoom: zoom)
                DayFoot(history: home.nodes.history, minuteMs: home.site.minuteMs)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .onAppear {
            home.nodes.history.activate()
            home.savings.activate()
            home.prices.activate()
            visible = true
            LaunchClock.mark("first content")
        }
        .onDisappear {
            home.nodes.history.deactivate()
            home.savings.deactivate()
            home.prices.deactivate()
            visible = false
        }
        // The car's ledger, once the box has said the home has a charger:
        // the chargers can arrive after the tab appears.
        .onChange(of: visible && hasCharger, initial: true) { _, want in
            guard want != carAsked else { return }
            carAsked = want
            if want { home.nodes.carEnergy.activate() } else { home.nodes.carEnergy.deactivate() }
        }
    }
}

/// "18,40 kr", "Saved today so far", into the savings view.
private struct HistorySavings: View {
    let home: HomeModels
    let zoom: Namespace.ID
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var unitSize: CGFloat = 20

    var body: some View {
        let glance = SavingsGlance.make(period: .day, answer: home.savings.week, problem: home.savings.problem, nowMs: home.site.minuteMs, currency: home.prices.currency)
        let r = glance.reading
        NavigationLink(value: HomeRoute.savings) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(r.figure)
                            .font(Theme.figure(figureSize))
                            .tracking(-1)
                            .foregroundStyle(r.known ? Theme.ink : Theme.ink3)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(r.unit)
                            .font(.system(size: unitSize, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    Text(r.word)
                        .font(.headline)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    // `AS OF 14:32`, or saved on this phone: the figure is
                    // the box's last word, dated.
                    Text(glance.footer.isEmpty ? " " : glance.footer)
                        .font(Theme.mono())
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .redacted(reason: glance.placeholder ? .placeholder : [])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: HomeRoute.savings, in: zoom)
        .animation(Theme.spring, value: r)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .modifier(NotReadYet(placeholder: glance.placeholder, label: L("Savings")))
        .accessibilityHint(L("Opens what your home saved."))
        .accessibilityIdentifier("history.savings")
    }
}

/// One element for VoiceOver: what it says, or while it holds only the
/// shape of what will come, its name and that it is not read yet.
private struct NotReadYet: ViewModifier {
    let placeholder: Bool
    let label: String

    func body(content: Content) -> some View {
        if placeholder {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(L("Not read yet"))
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// A row per node of the home, in the order a day is told: what the sun
/// made, what the home used, what the battery stored and gave, what the
/// grid sold and bought, what the car took. This view reads the stream
/// only for which nodes the home has; the rows below it redraw when the
/// tiles, the car's ledger or the minute move, never on a reading.
private struct DayRows: View {
    let home: HomeModels
    let zoom: Namespace.ID

    static let order: [EnergyNode] = [.solar, .home, .battery, .grid, .car]

    var body: some View {
        let site = home.site
        let nodes = NowFlow.nodes(fields: site.session.fields, hasCar: !home.loadpoints.points.isEmpty, known: site.kept?.nodes ?? [])
        if home.nodes.history.available {
            DayList(nodes: Self.order.filter { nodes.contains($0) }, home: home, zoom: zoom)
                .equatable()
        } else {
            Hint(L("Your box keeps no history."))
                .padding(.vertical, 12)
        }
    }
}

private struct DayList: View, Equatable {
    let nodes: [EnergyNode]
    let home: HomeModels
    let zoom: Namespace.ID

    nonisolated static func == (a: Self, b: Self) -> Bool { a.nodes == b.nodes }

    var body: some View {
        let history = home.nodes.history
        let midnight = history.midnightMs
        let now = home.site.minuteMs
        VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element) { i, node in
                if i > 0 { Divider().overlay(Theme.line).padding(.leading, DayRow.indent) }
                NavigationLink(value: HomeRoute.day(node)) {
                    DayRow(day: Self.day(node, history: history, car: home.nodes.carEnergy, midnight: midnight, nowMs: now))
                        .equatable()
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: HomeRoute.day(node), in: zoom)
                .accessibilityIdentifier("history.node.\(node.rawValue)")
            }
            DayAxis()
                .padding(.leading, DayRow.indent)
        }
    }

    /// One row's values, made once per change of tiles or minute. A row
    /// is known once something since midnight is: until then it holds its
    /// shape, redacted, and a tile on its way never counts as missing, so a
    /// day the phone has not been told yet never reads as zero.
    @MainActor
    static func day(_ node: EnergyNode, history: HistoryModel, car: CarEnergyModel, midnight: Double, nowMs: Double) -> DayRow.Day {
        let elapsed = min(1, max(0, (nowMs - midnight) / 86_400_000))
        if node == .car {
            guard car.loaded else {
                return car.problem.map { DayRow.Day(node: node, line: $0, note: nil, known: true, spark: .none, elapsed: elapsed) } ?? .waiting(node)
            }
            let hours = car.hours.filter { $0.startMs + $0.lenMs > midnight }
            let bars = hours.map { DayRow.Bar(at: ($0.startMs - midnight) / 86_400_000, width: $0.lenMs / 86_400_000, wh: $0.wh) }
            return DayRow.Day(node: node, line: DayWords.car(wh: car.wh(sinceMs: midnight)), note: nil, known: true, spark: .bars(bars), elapsed: elapsed)
        }
        // Nothing told since midnight: the box has not been asked, or its
        // answer is on its way.
        guard let e = history.today(node) else {
            return history.problem.map { DayRow.Day(node: node, line: $0, note: nil, known: true, spark: .none, elapsed: elapsed) } ?? .waiting(node)
        }
        let samples = history.samples(node, fromMs: midnight)
        let line = samples.map { s in s.watts.map { DayRow.Point(at: (s.startMs - midnight) / 86_400_000, w: $0) } }
        return DayRow.Day(node: node, line: DayWords.line(node, e), note: DayWords.missing(e), known: true, spark: .line(line), elapsed: elapsed)
    }
}

/// One node's day: its name in its colour, what it did in words, and the
/// day so far drawn small on the right, midnight to midnight, so the line
/// ends where the day has got to.
private struct DayRow: View, Equatable {
    struct Point: Equatable { var at: Double; var w: Double }
    struct Bar: Equatable { var at: Double; var width: Double; var wh: Double }
    enum Spark: Equatable {
        case none
        /// Five-minute means; nil is a hole the box has no record for.
        case line([Point?])
        /// The car's hours from the box's energy ledger.
        case bars([Bar])
    }

    struct Day: Equatable {
        var node: EnergyNode
        var line: String
        var note: String?
        /// The box said; false holds the row's shape before it does.
        var known: Bool
        var spark: Spark
        /// How far the day has got, 0 to 1.
        var elapsed: Double

        static func waiting(_ node: EnergyNode) -> Day {
            Day(node: node, line: DayWords.shape(node), note: nil, known: false, spark: .none, elapsed: 0)
        }
    }

    let day: Day

    /// From the row's edge to its words and its strip, so every strip
    /// starts at the same x and the five read as one day.
    static let indent: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: NodeLook.symbol(day.node))
                .font(.title3)
                .foregroundStyle(NodeChartLook.color(day.node))
                // A mark in a fixed gutter: it keeps the strips' common x
                // at every text size.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: Self.indent - 12, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.node.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink3)
                }
                Text(day.line)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .redacted(reason: day.known ? [] : .placeholder)
                    .contentTransition(.numericText())
                if let note = day.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
                DaySpark(node: day.node, spark: day.spark, elapsed: day.elapsed)
                    .frame(height: 30)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(Theme.spring, value: day.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.node.title)
        // The redacted shape is not a value.
        .accessibilityValue(day.known ? [day.line, day.note].compactMap { $0 }.joined(separator: ", ") : L("Not read yet"))
        .accessibilityHint(L("Opens this day's chart."))
        .accessibilityAddTraits(.isButton)
    }
}

/// The day so far, small: a hairline from midnight to midnight, and the
/// node's power on it in its colour, the battery's giving and the grid's
/// selling under the line. No glow: history is never live.
private struct DaySpark: View {
    let node: EnergyNode
    let spark: DayRow.Spark
    let elapsed: Double
    @Environment(\.colorScheme) private var scheme

    /// Nodes whose power runs both ways draw from a middle line.
    private var twoWay: Bool { node == .battery || node == .grid }

    var body: some View {
        Canvas { g, size in
            let base = twoWay ? size.height / 2 : size.height - 1
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: base))
            axis.addLine(to: CGPoint(x: size.width, y: base))
            g.stroke(axis, with: .color(Theme.ink.opacity(scheme == .dark ? 0.16 : 0.12)), lineWidth: 1)
            for quarter in 1...3 {
                let x = size.width * CGFloat(quarter) / 4
                var hour = Path()
                hour.move(to: CGPoint(x: x, y: 0))
                hour.addLine(to: CGPoint(x: x, y: size.height))
                g.stroke(hour, with: .color(Theme.ink.opacity(scheme == .dark ? 0.08 : 0.06)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }
            let look = NodeChartLook.look(node)
            switch spark {
            case .none:
                break
            case .bars(let bars):
                let top = max(1_000, bars.map(\.wh).max() ?? 0)
                for b in bars where b.wh > 0 {
                    let h = max(1.5, (size.height - 2) * b.wh / top)
                    let rect = CGRect(x: b.at * size.width + 0.5, y: base - h, width: max(1, b.width * size.width - 1), height: h)
                    g.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(look.up.opacity(0.85)))
                }
            case .line(let points):
                let top = max(200, points.compactMap { $0.map { abs($0.w) } }.max() ?? 0)
                let reach = twoWay ? size.height / 2 - 1 : size.height - 2
                func y(_ w: Double) -> CGFloat { base - CGFloat(w / top) * reach }
                var line = Path(), body = Path()
                var open = false, firstX: CGFloat = 0, lastX: CGFloat = 0
                func close() {
                    guard open else { return }
                    body.addLine(to: CGPoint(x: lastX, y: base))
                    body.addLine(to: CGPoint(x: firstX, y: base))
                    body.closeSubpath()
                    open = false
                }
                for p in points {
                    guard let p else { close(); continue }
                    let pt = CGPoint(x: p.at * size.width, y: y(p.w))
                    if open {
                        line.addLine(to: pt); body.addLine(to: pt)
                    } else {
                        line.move(to: pt)
                        body.move(to: CGPoint(x: pt.x, y: base)); body.addLine(to: pt)
                        firstX = pt.x; open = true
                    }
                    lastX = pt.x
                }
                close()
                let above = Path(CGRect(x: 0, y: 0, width: size.width, height: base))
                let below = Path(CGRect(x: 0, y: base, width: size.width, height: size.height - base))
                for (side, color) in [(above, look.up), (below, look.down)] {
                    var s = g
                    s.clip(to: side)
                    s.fill(body, with: .color(color.opacity(scheme == .dark ? 0.22 : 0.14)))
                    s.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: TraceInk.smallLine, lineCap: .round, lineJoin: .round))
                }
            }
            // Where the day has got to.
            if elapsed > 0, elapsed < 1 {
                let x = elapsed * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: base - 3))
                tick.addLine(to: CGPoint(x: x, y: base + 3))
                g.stroke(tick, with: .color(Theme.ink3), lineWidth: 1)
            }
        }
    }
}

/// The hours under the strips, at the strips' own quarter lines.
private struct DayAxis: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<4) { q in
                Text(verbatim: String(format: "%02d", q * 6))
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink3)
                    .fixedSize()
                    .position(x: q == 0 ? 8 : geo.size.width * CGFloat(q) / 4, y: geo.size.height / 2)
            }
        }
        .frame(height: 16)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityHidden(true)
    }
}

/// `AS OF 14:35`: where the tiles end, or FTW Cloud's dated copy, or why
/// there is nothing.
private struct DayFoot: View {
    let history: HistoryModel
    let minuteMs: Double

    var body: some View {
        // The five minutes still filling end after now; the tiles reach no
        // further than the clock.
        let text = history.cloudNote(nowMs: minuteMs) ?? history.problem ?? end.map { at in
            let t = min(at, minuteMs)
            return NodeWords.format("AS OF %@", t < history.midnightMs ? Clock.dayAndTime(t).uppercased() : Clock.time(t))
        }
        Text(text ?? " ")
            .font(Theme.mono())
            .tracking(0.5)
            .foregroundStyle(Theme.ink3)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The end of the newest five minutes with a value.
    private var end: Double? {
        guard let frame = history.frame, frame.points > 0 else { return nil }
        for i in stride(from: frame.points - 1, through: 0, by: -1) where HistoryModel.series.contains(where: { frame.value($0, at: i) != nil }) {
            return frame.time(at: i) + frame.stepMs
        }
        return nil
    }
}
