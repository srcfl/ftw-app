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
    @Binding var path: [HomeRoute]
    @State private var visible = false
    @State private var carAsked = false
    /// Read here for one reason: whether anyone has moved a row yet.
    @AppStorage(HistoryOrder.key) private var order = ""
    /// Which row is in hand, held here because the day does not scroll
    /// under one.
    @State private var hold = DayHold()

    private var hasCharger: Bool { !home.loadpoints.points.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HistorySavings(home: home, zoom: zoom)
                    .padding(.bottom, 24)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Kicker(L("Today"))
                    // How to move a row, while nobody has moved one.
                    if order.isEmpty, home.nodes.history.available {
                        Spacer(minLength: 0)
                        Text(L("Hold to move").uppercased())
                            .font(Theme.mono())
                            .tracking(0.5)
                            .foregroundStyle(Theme.ink3)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 2)
                DayRows(home: home, zoom: zoom, hold: hold, path: $path)
                DayFoot(history: home.nodes.history, minuteMs: home.site.minuteMs)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(hold.row != nil)
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

/// A row per node of the home and one for what power cost, in the order a
/// day is told until someone holds a row and moves it: what the sun made,
/// what the home used, what the battery stored and gave, what the grid sold
/// and bought, what the car took, what it cost. This view reads the stream
/// only for which nodes the home has; the rows below it redraw when the
/// tiles, the car's ledger or the minute move, never on a reading.
private struct DayRows: View {
    let home: HomeModels
    let zoom: Namespace.ID
    let hold: DayHold
    @Binding var path: [HomeRoute]
    /// The order this phone was left in, empty until someone moves a row.
    @AppStorage(HistoryOrder.key) private var order = ""

    var body: some View {
        let site = home.site
        let nodes = NowFlow.nodes(fields: site.session.fields, hasCar: !home.loadpoints.points.isEmpty, known: site.kept?.nodes ?? [])
        if home.nodes.history.available {
            DayList(
                rows: HistoryOrder.rows(stored: order, nodes: nodes, price: home.prices.available),
                order: $order, home: home, zoom: zoom, hold: hold, path: $path)
                .equatable()
        } else {
            // A box that keeps no history can still serve prices: the
            // market's day is not the home's record.
            VStack(alignment: .leading, spacing: 0) {
                Hint(L("Your box keeps no history."))
                    .padding(.vertical, 12)
                if home.prices.available {
                    Divider().overlay(Theme.line).padding(.leading, DayRow.indent)
                    PriceDayLink(home: home, zoom: zoom)
                        .contentShape(.rect)
                        .onTapGesture { path.append(.price(priceDay(home).fromMs)) }
                    DayAxis().padding(.leading, DayRow.indent)
                }
            }
        }
    }
}

/// Which row is in hand. The list sets it, the tab reads it: a day that
/// scrolled under a carried row would take it with it.
@MainActor @Observable final class DayHold {
    var row: HistoryRow?
}

/// The day's rows on one axis, and the hold that moves one. A held row
/// follows the finger while the others make room for it; nothing is kept
/// until the finger lets go, and then only on this phone.
private struct DayList: View, Equatable {
    let rows: [HistoryRow]
    @Binding var order: String
    let home: HomeModels
    let zoom: Namespace.ID
    let hold: DayHold
    @Binding var path: [HomeRoute]

    /// How far the row in hand has been carried, and where it would land.
    /// This view alone holds them, so a drag redraws the rows and nothing
    /// above them.
    @State private var carried: CGFloat = 0
    @State private var place = 0
    /// Each row as tall as it is drawn, so a carried row passes a row at
    /// that row's own middle, whatever the text size.
    @State private var heights: [String: CGFloat] = [:]
    /// True while a finger is on a row. SwiftUI clears it however the
    /// gesture ends, so a hold the system takes away still lets go.
    @GestureState private var touching = false

    nonisolated static func == (a: Self, b: Self) -> Bool { a.rows == b.rows }

    var body: some View {
        let history = home.nodes.history
        let midnight = history.midnightMs
        let now = home.site.minuteMs
        // The order on screen: while a row is in hand, where it would land.
        let shown = hold.row.map { HistoryOrder.moved(rows, $0, to: place) } ?? rows
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { i, row in
                let inHand = row == hold.row
                let shift = offset(i, row: row)
                VStack(spacing: 0) {
                    // A hairline where two rows meet, by what the eye
                    // sees: the row at the top of the list has none.
                    if row != shown.first {
                        Divider().overlay(Theme.line).padding(.leading, DayRow.indent)
                    }
                    door(row, history: history, midnight: midnight, now: now)
                        .contentShape(.rect)
                        // A tap on the row opens it, and is read before
                        // the hold outside it; a hold beats it to the
                        // draw, so a row that lifts never opens.
                        .onTapGesture { open(row) }
                        .accessibilityAction { open(row) }
                        .accessibilityActions { moves(row) }
                }
                .background {
                    // In hand, not in a box: the raised ground says the
                    // row has left the list, and goes with it.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.raised)
                        .opacity(inHand ? 1 : 0)
                }
                .shadow(color: .black.opacity(inHand ? 0.22 : 0), radius: 12, y: 4)
                .scaleEffect(inHand ? 1.02 : 1)
                .offset(y: shift)
                .zIndex(inHand ? 1 : 0)
                // The carried row keeps up with the finger; the rows it
                // passes glide out of its way.
                .animation(inHand ? nil : Theme.spring, value: shift)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[row.key] = $0 }
                .gesture(lift(row, at: i))
            }
            DayAxis()
                .padding(.leading, DayRow.indent)
        }
        .onChange(of: touching) { _, on in if !on { drop() } }
        .sensoryFeedback(.impact(weight: .light), trigger: hold.row != nil) { _, lifted in lifted }
        .sensoryFeedback(.selection, trigger: place) { _, _ in hold.row != nil }
    }

    /// One row, and what it draws. It is no button: a button's own press
    /// would take the hold that moves it, so the row's gesture opens it.
    @ViewBuilder private func door(_ row: HistoryRow, history: HistoryModel, midnight: Double, now: Double) -> some View {
        switch row {
        case .node(let node):
            DayRow(day: Self.day(node, history: history, car: home.nodes.carEnergy, midnight: midnight, nowMs: now))
                .equatable()
                .matchedTransitionSource(id: HomeRoute.day(node), in: zoom)
                .accessibilityIdentifier("history.node.\(node.rawValue)")
        case .price:
            PriceDayLink(home: home, zoom: zoom)
        }
    }

    /// What a row opens: that node's day, or that day's prices.
    private func open(_ row: HistoryRow) {
        switch row {
        case .node(let node): path.append(.day(node))
        case .price: path.append(.price(priceDay(home).fromMs))
        }
    }

    /// Moving a row without a finger, for VoiceOver and Full Keyboard
    /// Access.
    @ViewBuilder private func moves(_ row: HistoryRow) -> some View {
        if let i = rows.firstIndex(of: row) {
            if i > 0 {
                Button(L("Move up")) { keep(HistoryOrder.moved(rows, row, to: i - 1)) }
            }
            if i < rows.count - 1 {
                Button(L("Move down")) { keep(HistoryOrder.moved(rows, row, to: i + 1)) }
            }
        }
    }

    /// Hold a row to lift it, drag to carry it, let go to keep it there.
    /// Behind the row's own tap, which a hold is not, and ahead of the
    /// day's scroll, which stops while a row is in hand.
    private func lift(_ row: HistoryRow, at i: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($touching) { _, on, _ in on = true }
            .onChanged { step in
                switch step {
                case .first(true):
                    guard hold.row == nil, rows.count > 1 else { return }
                    withAnimation(Theme.spring) {
                        hold.row = row
                        carried = 0
                        place = i
                    }
                case .second(true, let drag):
                    guard hold.row == row, let drag else { return }
                    carried = drag.translation.height
                    place = target(from: i, carried: carried)
                default:
                    break
                }
            }
            .onEnded { _ in drop() }
    }

    /// How far a row stands from where the list would put it: the carried
    /// row is where the finger is, and a row between its place and where it
    /// would land has moved over by the carried row's height.
    private func offset(_ i: Int, row: HistoryRow) -> CGFloat {
        guard let held = hold.row, let from = rows.firstIndex(of: held) else { return 0 }
        if row == hold.row { return carried }
        let tall = heights[held.key] ?? 0
        if place > from, i > from, i <= place { return -tall }
        if place < from, i >= place, i < from { return tall }
        return 0
    }

    /// Where a row carried this far would land: past the middle of each row
    /// it has covered.
    private func target(from: Int, carried: CGFloat) -> Int {
        var place = from
        var covered: CGFloat = 0
        var i = carried > 0 ? from + 1 : from - 1
        let step = carried > 0 ? 1 : -1
        while i >= 0, i < rows.count {
            let tall = heights[rows[i].key] ?? 0
            guard abs(carried) > covered + tall / 2 else { break }
            place = i
            covered += tall
            i += step
        }
        return place
    }

    private func drop() {
        guard let row = hold.row else { return }
        withAnimation(Theme.spring) {
            order = HistoryOrder.stored(HistoryOrder.moved(rows, row, to: place))
            hold.row = nil
            carried = 0
        }
    }

    /// The order this phone keeps from now on.
    private func keep(_ rows: [HistoryRow]) {
        withAnimation(Theme.spring) { order = HistoryOrder.stored(rows) }
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
                    s.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
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

/// The day the price row shows and the day it opens, read once: the
/// household's own day, midnight to midnight.
@MainActor private func priceDay(_ home: HomeModels) -> TimelineWindow {
    TimelineWindow.today(nowMs: home.site.minuteMs, clock: ZoneClock.of(.current))
}

/// History's price row: the price screen on this same day lies behind it.
/// Reads the minute and the prices, and hands the row a value, so a reading
/// redraws nothing here. Like the node rows it is no button; the row's own
/// gesture opens it.
private struct PriceDayLink: View {
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        let clock = ZoneClock.of(.current)
        let today = priceDay(home)
        let prices = home.prices
        // Today's prices are in the window Now already asked for; the days
        // behind are the price screen's own read.
        let shown = prices.window == nil
            ? PriceDayRow.Shown.waiting(currency: prices.currency)
            : PriceDayRow.Shown(
                day: prices.day(fromMs: today.fromMs, toMs: today.toMs, clock: clock),
                elapsed: min(1, max(0, (home.site.minuteMs - today.fromMs) / today.spanMs))
            )
        PriceDayRow(shown: shown)
            .equatable()
            .matchedTransitionSource(id: HomeRoute.price(today.fromMs), in: zoom)
            .accessibilityIdentifier("history.price")
    }
}

/// What power cost today, in the nodes' own shape and on their axis: the
/// price tag in ink, the day's average and its cheapest slot in words, and
/// the day drawn midnight to midnight as bars by level.
///
/// The figure is the total, what the household pays, as every other price
/// in the app is; the price screen this row opens says what the total
/// holds. A slot the box has no price for draws nothing and is said in
/// words, never drawn as nothing to pay.
private struct PriceDayRow: View, Equatable {
    struct Shown: Equatable {
        var line: String
        var note: String?
        var bars: [PriceDay.Bar]
        /// The box said; false holds the row's shape before it does.
        var known: Bool
        /// How far the day has got, 0 to 1.
        var elapsed: Double

        init(day: PriceDay, elapsed: Double) {
            line = day.line
            note = day.note
            bars = day.bars
            known = true
            self.elapsed = elapsed
        }

        init(line: String, note: String?, bars: [PriceDay.Bar], known: Bool, elapsed: Double) {
            self.line = line
            self.note = note
            self.bars = bars
            self.known = known
            self.elapsed = elapsed
        }

        /// The shape the row holds until the box has said anything.
        static func waiting(currency: String) -> Shown {
            Shown(line: PriceDay.shape(currency: currency), note: nil, bars: [], known: false, elapsed: 0)
        }
    }

    let shown: Shown

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tag.fill")
                .font(.title3)
                .foregroundStyle(Theme.ink2)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: DayRow.indent - 12, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Electricity price"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink3)
                }
                Text(shown.line)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .redacted(reason: shown.known ? [] : .placeholder)
                    .contentTransition(.numericText())
                if let note = shown.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
                PriceSpark(bars: shown.bars, elapsed: shown.elapsed)
                    .frame(height: 30)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(Theme.spring, value: shown.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Electricity price"))
        .accessibilityValue(shown.known ? [shown.line, shown.note].compactMap { $0 }.joined(separator: ", ") : L("Not read yet"))
        .accessibilityHint(L("Opens this day's prices."))
        .accessibilityAddTraits(.isButton)
    }
}

/// The day's prices, small: a hairline day, the same quarter marks as the
/// nodes' strips, and a bar per slot in ink by its level — the dearer, the
/// stronger — as the price chart draws them. A slot with no price leaves a
/// gap. No glow: a price is never live.
private struct PriceSpark: View {
    let bars: [PriceDay.Bar]
    let elapsed: Double
    @Environment(\.colorScheme) private var scheme

    private static let ink: [PriceChart.Third: Double] = [.cheap: 0.32, .middle: 0.5, .dear: 0.8]

    var body: some View {
        Canvas { g, size in
            // Below zero exists in this market: the day's bars hang from
            // where nothing costs anything.
            let lo = min(0, bars.map(\.minor).min() ?? 0)
            let hi = max(0, bars.map(\.minor).max() ?? 0)
            let reach = size.height - 2
            let base = hi > lo ? 1 + reach * hi / (hi - lo) : size.height - 1
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
            let span = hi - lo
            for bar in bars where bar.minor != 0 {
                let height = span > 0 ? reach * abs(bar.minor) / span : 0
                guard height > 0 else { continue }
                let h = max(1.5, height)
                let rect = CGRect(
                    x: bar.at * size.width,
                    y: bar.minor > 0 ? base - h : base,
                    width: max(1, bar.width * size.width - 0.5),
                    height: h
                )
                g.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.ink.opacity(Self.ink[bar.third] ?? 0.5)))
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
