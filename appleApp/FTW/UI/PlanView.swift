import Charts
import FTWKit
import SwiftUI

/// The plan, opened from Now: the next 24 hours round the plan dial, or
/// the next twelve hours in lanes, then each thing the box means to do,
/// when, and why, in the box's own reasons. The dial is the default; the
/// lanes are one tap away in the toolbar, and the phone keeps the viewer's
/// choice.
struct PlanView: View {
    let app: AppModel
    let home: HomeModels
    @State private var choosingMode = false
    /// The viewer's own choice, kept on this phone. `-FTWPlanStyle lanes`
    /// at launch holds it there, for screenshots and tests.
    @AppStorage("FTWPlanStyle") private var style: PlanStyle = .dial
    /// A finger scrubs the dial: the page holds still under it.
    @State private var dialHolds = false
    @State private var dialTouch = DialTouch()

    private var models: NodeModels { home.nodes }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlanBody(site: home.site, models: models, loadpoints: home.loadpoints, prices: home.prices, style: style, chooseMode: { choosingMode = true }, dialHolds: $dialHolds, dialTouch: dialTouch) { levers in
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(levers ? PlanBody.leversID : PlanBody.topID, anchor: levers ? .bottom : .top) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(dialHolds)
            // Every touch, beside the scroll, for the dial's ring: a
            // gesture on the ring itself stops the page scrolling. None
            // from the screen's leading 20 pt, which are the back swipe's.
            .leavesTheEdge()
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { dialTouch.changed?($0) }
                    .onEnded { _ in dialTouch.ended?() }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .navigationTitle(PlanGlance.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker(L("Show the plan as"), selection: $style.animation(.easeInOut(duration: 0.25))) {
                    ForEach(PlanStyle.allCases, id: \.self) { s in
                        Image(systemName: s.symbol)
                            .accessibilityLabel(s.label)
                            .tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("plan.style")
            }
        }
        .onAppear {
            // The forecast gives the dial its sky: the same read the sun's
            // and the home's views make.
            models.plan.activate(forecast: true)
            models.mode.activate()
            home.prices.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            models.plan.deactivate(forecast: true)
            models.mode.deactivate()
            home.prices.deactivate()
        }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode, plan: models.planShare)
        }
    }
}

/// How the plan view draws the plan: round on the dial, or straight in
/// lanes.
enum PlanStyle: String, CaseIterable {
    case dial, lanes

    var label: String {
        switch self {
        case .dial: return L("Dial")
        case .lanes: return L("Lanes")
        }
    }

    var symbol: String {
        switch self {
        case .dial: return "circle.dashed"
        case .lanes: return "chart.bar.xaxis"
        }
    }
}

private struct PlanBody: View {
    let site: SiteModel
    let models: NodeModels
    let loadpoints: LoadpointsModel
    let prices: PriceModel
    let style: PlanStyle
    let chooseMode: () -> Void
    @Binding var dialHolds: Bool
    let dialTouch: DialTouch
    /// Scrolls to the levers, or back to the plan, for the style scale's
    /// recording.
    let reveal: (Bool) -> Void
    @State private var dials = DialMemo()

    static let topID = "plan.top"
    static let leversID = "plan.levers"

    var body: some View {
        // The plan marks the minute: it redraws once a minute, not a second.
        let minute = site.minuteMs
        let moment = models.planShare.moment(nowMs: minute)
        let moved = models.planShare.moved
        Group {
            switch style {
            case .dial:
                let dial = dials.dial(models.planShare.entry, nowMs: minute)
                VStack(alignment: .leading, spacing: 12) {
                    PlanDialCard(dial: dial, grey: moment.isGrey, fade: DialFade.make(models.planShare.before, dial: dial, nowMs: minute), holds: $dialHolds, touch: dialTouch)
                    VStack(alignment: .leading, spacing: 6) {
                        // The words are the dial's legend: each verb takes
                        // the colour its ticks have.
                        PlanStory(moment: moment)
                        MovedLine(text: moved)
                        // Mono stops growing at accessibility1.
                        Group {
                            if let cheapest = dial.cheapestText {
                                Text(cheapest).foregroundStyle(Theme.ink2)
                            }
                            // What the planner reckons the plan saves, only
                            // where it compares honestly.
                            if let saving = models.plan.saving?.text(currency: models.planShare.entry.currency, nowMs: minute, zone: dial.zone) {
                                Text(saving).foregroundStyle(Theme.ink2)
                            }
                            Text(plannedLine(moment, zone: dial.zone))
                                .foregroundStyle(moment.state == .boxStale ? Theme.alarm : Theme.ink3)
                            // What the plan rests on: the prices are known,
                            // the sun and the home's use are a forecast, and
                            // a style other than balanced leans on it less or
                            // more.
                            if let lean = styleLine {
                                Text(lean).foregroundStyle(Theme.ink3)
                            }
                        }
                        .font(Theme.mono())
                        .tracking(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    }
                }
                .transition(.opacity)
            case .lanes:
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(moment.summary)
                            .font(.headline)
                            .foregroundStyle(moment.isGrey ? Theme.fgDim : Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                            .redacted(reason: moment.placeholder ? .placeholder : [])
                        Text(stateLine(moment))
                            .font(.footnote)
                            .foregroundStyle(moment.state == .boxStale ? Theme.alarm : Theme.fgDim)
                        MovedLine(text: moved)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PlanLanes(moment: moment)
                            .equatable()
                            .frame(height: 140)
                        Legend(kinds: Set(moment.events.map(\.kind)), level: !moment.levels.isEmpty)
                    }
                }
                .transition(.opacity)
            }
        }
        .id(Self.topID)
        PriceRow(prices: prices, minute: minute)
        // Under the dial the story already says what each row would.
        if style == .lanes {
            Events(moment: moment, entry: models.planShare.entry, loadpoints: loadpoints, style: style)
        }
        Levers(mode: models.mode, loadpoints: loadpoints, minute: minute, choose: chooseMode, reveal: reveal)
            .id(Self.leversID)
    }

    /// "PLANNED 16:51 · REPLANS EVERY 15 MIN", or that the box could not.
    private func plannedLine(_ m: PlanGlance.Moment, zone: TimeZone) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return PlanDial.planned(atMs: at, old: m.state == .old, zone: zone)
    }

    /// "CAREFUL WITH THE FORECAST", when the planning style is not
    /// balanced. Nothing when it is, or before the box has said.
    private var styleLine: String? {
        guard let style = models.mode.shownStyle, style.key != "balanced" else { return nil }
        return NodeWords.format("%@ with the forecast", NodeWords.text(style.name)).uppercased()
    }

    /// When the box made it, or that it could not.
    private func stateLine(_ m: PlanGlance.Moment) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return NodeWords.format("Planned by your box at %@. It plans again every quarter of an hour.", AppWords.clock(at, zone: m.timeZone))
    }
}

/// The plan under the dial in up to three sentences, each verb in the
/// colour of its ticks: ink gives power, cyan stores, violet for the car.
/// Before the box has answered, the plan's own line in its shape.
private struct PlanStory: View {
    let moment: PlanGlance.Moment

    var body: some View {
        Group {
            if moment.story.isEmpty {
                Text(moment.summary)
                    .foregroundStyle(moment.isGrey ? Theme.ink3 : Theme.ink2)
                    .redacted(reason: moment.placeholder ? .placeholder : [])
            } else {
                moment.story.enumerated().reduce(Text(verbatim: "")) { text, item in
                    let (i, phrase) = item
                    return text + Text(verbatim: i == 0 ? "" : " ") + sentence(phrase)
                }
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func sentence(_ phrase: PlanGlance.Phrase) -> Text {
        phrase.parts.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (i, part) = item
            let verb = i % 2 == 1
            return text + Text(verbatim: part)
                .foregroundStyle(verb && !moment.isGrey ? color(phrase.kind) : (moment.isGrey ? Theme.ink3 : Theme.ink2))
                .fontWeight(verb ? .semibold : .regular)
        }
    }

    /// The dial's colours: on the dial gold is the sun's, so giving power is
    /// ink.
    private func color(_ kind: PlanGlance.Kind) -> Color {
        switch kind {
        case .charge: return Theme.stores
        case .discharge: return Theme.ink
        case .car: return Theme.car
        case .cheap: return Theme.ink2
        }
    }
}

/// The dial worked out once per plan and minute, so a body that runs again
/// for any other reason reads it.
@MainActor
private final class DialMemo {
    private var key: (entry: PlanEntry, minute: Double)?
    private var kept: PlanDial?

    func dial(_ entry: PlanEntry, nowMs: Double) -> PlanDial {
        if let key, key.entry == entry, key.minute == nowMs, let kept { return kept }
        let d = PlanDial(plan: entry, prices: nil, nowMs: nowMs)
        key = (entry, nowMs)
        kept = d
        return d
    }
}

/// What each colour on the lanes means.
private struct Legend: View {
    let kinds: Set<PlanGlance.Kind>
    var level = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
        .font(.caption2)
        .foregroundStyle(Theme.fgDim)
    }

    /// Only what the lanes hold, in short words: the rows below say the rest.
    @ViewBuilder private var items: some View {
        if kinds.contains(.car) { item(.car, L("Car")) }
        if kinds.contains(.charge) { item(.charge, L("charging")) }
        if kinds.contains(.discharge) { item(.discharge, L("discharging")) }
        if kinds.contains(.cheap) { item(.cheap, L("Cheapest")) }
        if level {
            HStack(spacing: 4) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 3))
                    p.addLine(to: CGPoint(x: 12, y: 3))
                }
                .stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [3, 3]))
                .frame(width: 12, height: 6)
                Text(L("battery level")).lineLimit(1)
            }
        }
    }

    private func item(_ kind: PlanGlance.Kind, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(PlanLanes.color(kind)).frame(width: 10, height: 6)
            Text(text).lineLimit(1)
        }
    }
}

/// Each thing the box means to do, when, and why, as plain rows on the
/// ground. Each row's mark has the colour the plan draws it in above, so
/// the rows are the legend.
private struct Events: View {
    let moment: PlanGlance.Moment
    let entry: PlanEntry
    let loadpoints: LoadpointsModel
    let style: PlanStyle

    var body: some View {
        VStack(spacing: 0) {
            let shown = Array(moment.events.prefix(4))
            if shown.isEmpty {
                Text(moment.summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider().overlay(Theme.line) }
                row(e)
            }
            if moment.events.count > shown.count {
                Text(NodeWords.format("%@ more later", String(moment.events.count - shown.count)))
                    .font(.caption)
                    .foregroundStyle(Theme.fgMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    /// On the dial gold is the sun's, so the battery giving power is ink
    /// there; the lanes keep gold.
    private func color(_ kind: PlanGlance.Kind) -> Color {
        style == .dial && kind == .discharge ? Theme.ink : PlanLanes.color(kind)
    }

    private func row(_ e: PlanGlance.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(e.kind))
                .frame(width: 10, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 1) {
                Text(PlanGlance.what(e))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.fg)
                if let why = why(e) {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 8)
            Text(range(e))
                .font(Theme.figure(13, weight: .medium))
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    /// "22:15–00:00", "now–04:47".
    private func range(_ e: PlanGlance.Event) -> String {
        let start = PlanGlance.started(e, at: moment.atMs) ? L("now") : AppWords.clock(e.startMs, zone: .current)
        return "\(start)–\(AppWords.clock(e.endMs, zone: .current))"
    }

    /// The box's reason, and what the numbers are.
    private func why(_ e: PlanGlance.Event) -> String? {
        switch e.kind {
        case .charge, .discharge:
            let reason = e.reason.map(PlanText.reason)
            let peak = e.peakW.map { NodeWords.format("up to %@", AppWords.power($0)) }
            return [reason, peak].compactMap { $0 }.joined(separator: " · ").capitalizedFirst
        case .car:
            let lp = loadpoints.points.first
            let goal = lp?.schedule.map { EVText.goal($0, at: Date(timeIntervalSince1970: moment.atMs / 1000), zone: loadpoints.zone) }
            let energy = e.energyWh.map { AppWords.energy($0) }
            let text = [energy, goal].compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? nil : text.capitalizedFirst
        case .cheap:
            let inBlock = entry.prices.filter { $0.startMs < e.endMs && $0.startMs + $0.durationMs > e.startMs }
            guard !inBlock.isEmpty else { return nil }
            let mean = inBlock.map(\.totalMinor).reduce(0, +) / Double(inBlock.count)
            let unit = PriceUnits.unit(entry.currency)
            return NodeWords.format("%@ on average", "\(AppWords.decimal(PriceStrip.text(mean, entry.currency))) \(unit.perKwh)")
        }
    }
}

/// The price the plan stands on, in one row, and the way to its chart.
private struct PriceRow: View {
    let prices: PriceModel
    let minute: Double

    var body: some View {
        if let window = prices.prices {
            let current = window.slots.first { minute >= $0.startMs && minute < $0.startMs + $0.durationMs }
            NavigationLink(value: HomeRoute.price) {
                HStack(alignment: .firstTextBaseline) {
                    Kicker(L("Electricity price"))
                    Spacer(minLength: 8)
                    if let current {
                        Text("\(Text(AppWords.decimal(PriceStrip.text(current.totalMinor, window.currency))).font(Theme.figure(15)).foregroundStyle(Theme.fg)) \(Text(PriceUnits.unit(window.currency).perKwh).font(.caption2).foregroundStyle(Theme.fgMuted))")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.fgMuted)
                }
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.price")
        }
    }
}

/// "New plan 16:53: stores 22:45 instead of 03:45.", after a change of the
/// person's own, until the next plan.
private struct MovedLine: View {
    let text: String?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("plan.moved")
            }
        }
        .animation(.easeOut(duration: 0.2), value: text)
    }
}

/// What the person can change, at the foot of the plan: the car's goal,
/// the mode, and while the plan runs its style as a scale with five stops.
private struct Levers: View {
    let mode: ModeModel
    let loadpoints: LoadpointsModel
    let minute: Double
    let choose: () -> Void
    let reveal: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lp = loadpoints.points.first {
                NavigationLink(value: HomeRoute.car(lp.id)) {
                    row(L("Car"), value: goal(lp), tint: Theme.ink, symbol: "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plan.car")
                Divider().overlay(Theme.hairline)
            }
            if let label {
                Button(action: choose) {
                    row(L("Mode"), value: label, tint: mode.mayControl ? Theme.accent : Theme.ink, symbol: mode.mayControl ? "chevron.up.chevron.down" : nil)
                }
                .buttonStyle(.plain)
                .disabled(!mode.canControl)
                .accessibilityIdentifier("plan.mode")
            }
            if showsScale {
                #if DEBUG
                StyleScale(mode: mode, drives: true, reveal: reveal)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                #else
                StyleScale(mode: mode)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                #endif
            }
        }
    }

    /// The scale stands in for the style while the plan runs and this
    /// phone may change it; else the row names it.
    private var showsScale: Bool { mode.mayControl && mode.shownStyle != nil && ModeWords.isPlan(mode.shown ?? "") }

    /// "Plan" when the scale below says the style, else "Plan · Balanced"
    /// or a manual mode's name.
    private var label: String? {
        guard let key = mode.shown else { return mode.label }
        return showsScale && ModeWords.isPlan(key) ? L("Plan") : mode.label
    }

    /// "80 % by 07:00 on weekdays", the goal the plan charges for.
    private func goal(_ lp: Loadpoint) -> String {
        guard let s = lp.schedule else { return L("No goal") }
        return EVText.goal(s, at: Date(timeIntervalSince1970: minute / 1000), zone: loadpoints.zone)
    }

    private func row(_ kicker: String, value: String, tint: Color, symbol: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Kicker(kicker)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint == Theme.ink ? Theme.ink3 : tint)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private extension String {
    /// "Power is cheap · up to 3 kW": a sentence starts with a capital.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The hours ahead as lanes: the car's charging on top, the battery under
/// it (charging one colour, giving power another), the cheapest hours as a
/// thin mark, and the prices as a low strip along the bottom. The price is
/// the ground the plan stands on, not the subject.
struct PlanLanes: View, Equatable {
    let moment: PlanGlance.Moment
    var compact = false

    private static let car = 0.68...0.96
    private static let battery = 0.34...0.62
    private static let cheap = 0.23...0.27
    static let priceFloor = 0.03
    static let priceRise = 0.15

    var body: some View {
        let from = moment.atMs
        let to = from + PlanGlance.horizonMs
        let top = max(1, moment.backdrop.map(\.minor).max() ?? 1)
        let grey = moment.isGrey
        Chart {
            ForEach(moment.backdrop) { bar in
                RectangleMark(
                    xStart: .value("From", date(max(from, bar.startMs))),
                    xEnd: .value("To", date(min(to, bar.endMs))),
                    yStart: .value("Bottom", 0),
                    yEnd: .value("Price", Self.priceFloor + Self.priceRise * max(0, bar.minor) / top)
                )
                .foregroundStyle(grey ? Theme.fgMuted : Theme.price(bar.tone))
                .opacity(0.4)
            }
            ForEach(moment.events) { e in
                let lane = Self.lane(e.kind)
                RectangleMark(
                    xStart: .value("From", date(max(from, e.startMs))),
                    xEnd: .value("To", date(min(to, e.endMs))),
                    yStart: .value("Low", lane.lowerBound),
                    yEnd: .value("High", lane.upperBound)
                )
                .foregroundStyle(grey ? Theme.fgMuted : Self.color(e.kind))
                .cornerRadius(5)
                .annotation(position: .overlay, alignment: .center) {
                    if !compact || e.endMs - e.startMs >= 90 * 60_000, let pct = e.targetPct, e.kind == .car {
                        Text(AppWords.percent(pct))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ground)
                    }
                }
            }
            // Where the plan leads the battery: a ghost, dashed, because it
            // is a plan and not a reading. 0 % at the foot, 100 % at the top.
            ForEach(moment.levels.filter { $0.ms >= from && $0.ms <= to }, id: \.ms) { p in
                LineMark(x: .value("Time", date(p.ms)), y: .value("Level", p.pct / 100), series: .value("Series", "level"))
                    .foregroundStyle(grey ? Theme.fgMuted : Theme.ink2)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [3, 4]))
            }
            RuleMark(x: .value("Now", date(from)))
                .foregroundStyle(Theme.accentFill)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: date(from)...date(to))
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { value in
                AxisValueLabel { hourLabel(value) }
            }
        }
        .accessibilityHidden(true)
    }

    static func lane(_ kind: PlanGlance.Kind) -> ClosedRange<Double> {
        switch kind {
        case .car: return car
        case .charge, .discharge: return battery
        case .cheap: return cheap
        }
    }

    static func color(_ kind: PlanGlance.Kind) -> Color {
        switch kind {
        case .car: return Theme.car
        case .charge: return Theme.stores
        case .discharge: return Theme.gives
        case .cheap: return Theme.ink2
        }
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

/// "15", on the 24-hour clock FTW uses in both languages: an English phone
/// would otherwise label the afternoon "03".
private func hourLabel(_ value: AxisValue) -> some View {
    Text(value.as(Date.self).map { String(format: "%02d", Calendar.current.component(.hour, from: $0)) } ?? "")
        .font(.caption2)
        .foregroundStyle(Theme.ink3)
}
