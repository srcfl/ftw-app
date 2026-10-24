import FTWKit
import SwiftUI

/// One continuous timeline: the box's stored means, the live readings
/// built on them, and its plan or forecast after now. It opens on today;
/// drag through time, pinch to zoom, hold to read across the past, now
/// and what is planned. The same window opens on the whole screen.
struct NodeView: View {
    let app: AppModel
    let home: HomeModels
    let node: EnergyNode
    let zoom: Namespace.ID
    @State private var scrub = ScrubModel()
    @State private var choosingMode = false
    /// Every node opens on today; a drag or a pinch moves from there.
    @State private var window = TimelineWindow.today(nowMs: Date().timeIntervalSince1970 * 1000, clock: .of(.current))
    @State private var text = PeriodText()
    @State private var series: [EnergyNode]
    @State private var enlarged = false
    @Namespace private var chartZoom
    @Environment(\.dynamicTypeSize) private var typeSize

    init(app: AppModel, home: HomeModels, node: EnergyNode, zoom: Namespace.ID) {
        self.app = app
        self.home = home
        self.node = node
        self.zoom = zoom
        _series = State(initialValue: SeriesChoice.load(node))
        #if DEBUG
        let hours = UserDefaults.standard.double(forKey: "FTWTimelineHours")
        if hours > 0 {
            let now = Date().timeIntervalSince1970 * 1000
            var initial = TimelineWindow(nowMs: now, spanMs: hours * 3_600_000)
            let back = UserDefaults.standard.double(forKey: "FTWTimelineBackHours") * 3_600_000
            if back > 0 { initial = initial.transformed(anchor: 0, destination: back / initial.spanMs, magnification: 1, nowMs: now) }
            _window = State(initialValue: initial)
        }
        #endif
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
            // The same window can pan from stored history into the box's
            // plan or forecast.
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
        }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode, plan: models.planShare)
        }
        .fullScreenCover(isPresented: $enlarged) {
            TimelineFullScreen(site: site, node: node, home: home, window: $window, series: $series)
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

    /// `chartMax` is half the screen's height on the fixed page, nil where
    /// the page scrolls. On the fixed page the chart takes the height the
    /// rest leaves, from 200 pt up to `chartMax`; what is left after that
    /// sits between the chart and the picker, never at the foot.
    private func page(chartMax: CGFloat?) -> some View {
        let fill = chartMax != nil
        return VStack(alignment: .leading, spacing: 0) {
            NodeHero(site: site, node: node, home: home, scrub: scrub, text: text)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
            // Series choices keep their room while time moves.
            SeriesChips(own: node, available: Self.chartable(node), chosen: $series)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .fixedSize(horizontal: false, vertical: true)
            // A tap opens it on the whole screen, growing out of this one.
            // The chart's own overlay tells a tap from a scrub.
            TimelineChartArea(site: site, node: node, home: home, scrub: scrub, window: $window, series: series, text: text, onTap: { enlarged = true })
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
                TimelineControls(site: site, node: node, home: home, window: $window, scrub: scrub, text: text)
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
    let scrub: ScrubModel
    let text: PeriodText
    var followsChart = true
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
        // A held point names its evidence: interval mean, observation,
        // plan, forecast or a gap. The separate car plan keeps now here.
        let under = followsChart ? text.hero(scrub) : nil
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
                // The ring and its line are there whether a level is known
                // or not, so the hero keeps its height when one comes.
                let zone = home.loadpoints.zone
                if home.cars.keepsCars, let car = home.cars.shownCar, let level = home.cars.level(car) {
                    let goal = car.goal.map { CarsModel.schedule($0, nowMs: site.minuteMs, zone: zone) }.flatMap(CarText.goalPct)
                    levelRing(level.pct, text: CarText.percent(level), tint: Theme.car, lit: !level.guessed, glows: false, goal: goal)
                    carLine(CarText.originAndGoal(CarText.origin(level, nowMs: site.minuteMs, zone: zone), goalPct: goal))
                } else if let level = home.loadpoints.carLevel {
                    let guessed = level.origin == .assumed || level.origin == .unconfirmed
                    let lp = home.loadpoints.points.first(where: \.pluggedIn) ?? home.loadpoints.points.first
                    let goal = lp?.schedule.flatMap(CarText.goalPct)
                    levelRing(level.pct, text: (guessed ? "≈\u{00A0}" : "") + AppWords.percent(level.pct), tint: Theme.car, lit: !guessed, glows: false, goal: goal)
                    carLine(CarText.originAndGoal(EVText.originAged(level, nowMs: site.minuteMs, zone: zone), goalPct: goal))
                } else {
                    levelRing(0, text: "—", tint: Theme.car, lit: false, glows: false, goal: nil)
                    carLine(C("Level unknown"))
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

    /// Where the car's level comes from, and its goal, on one line.
    func carLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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

/// `VIA RELAY · SUNGROW · READS EVERY 1 S`: how the reading reaches the
/// phone, the device behind it, and how often the device itself reads,
/// from its readings. When this node is not live and the title does not
/// already give an age, it starts `○ AS OF 14:05`. One line, so the
/// controls over it never move.
struct NodeFooter: View {
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
