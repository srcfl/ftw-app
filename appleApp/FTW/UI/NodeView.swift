import FTWKit
import SwiftUI

/// One node of the flow, on one screen: the reading now and its last five
/// minutes, today and the last two days from the box's history, the hours
/// ahead from the box's plan with the price beside them, and the mode the
/// home runs in, with a way to change it.
///
/// The live part asks nothing: it reads lane 0 and the ring buffer the
/// frames fill. History and the plan are asked for when the view opens and
/// kept for the next visit.
struct NodeView: View {
    let app: AppModel
    let home: HomeModels
    let node: EnergyNode
    let zoom: Namespace.ID
    @State private var period: Period = .initial
    @State private var choosingMode = false

    enum Period: String, CaseIterable, Hashable {
        case today, twoDays, ahead

        /// Debug builds take `-FTWPeriod ahead` and the like, for screenshots.
        static var initial: Period {
            #if DEBUG
            return UserDefaults.standard.string(forKey: "FTWPeriod").flatMap(Period.init(rawValue:)) ?? .today
            #else
            return .today
            #endif
        }

        var label: String {
            switch self {
            case .today: return L("Today")
            case .twoDays: return L("48 h")
            case .ahead: return L("Ahead")
            }
        }
    }

    private var models: NodeModels { home.nodes }
    private var site: SiteModel { home.site }

    var body: some View {
        FitScreen(spacing: 12) { fill in
            NodeHero(site: site, node: node, loadpoints: home.loadpoints, sources: models.sources)
            LiveSection(site: site, trace: models.live, node: node)
                .frame(height: fill ? 92 : 120)
            Picker(L("Period"), selection: $period.animation(Theme.spring)) {
                ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("node.period")
            PeriodSection(site: site, node: node, period: period, models: models, prices: home.prices, loadpoints: home.loadpoints)
                .frame(minHeight: fill ? 150 : 210, idealHeight: fill ? 150 : 210, maxHeight: fill ? .infinity : 210)
            if node == .car {
                CarLink(loadpoints: home.loadpoints, zoom: zoom)
            } else {
                ModeSection(mode: models.mode, node: node, choose: { choosingMode = true })
            }
        }
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
        }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode)
        }
    }
}

// MARK: Now

/// The reading now, the way it flows, how full, and whether it is live.
private struct NodeHero: View {
    let site: SiteModel
    let node: EnergyNode
    let loadpoints: LoadpointsModel
    let sources: SourcesModel

    var body: some View {
        let fields = Flow.withLoadpointEV(site.session.fields, evW: loadpoints.stale ? 0 : Flow.loadpointChargeW(loadpoints.points))
        let car = loadpoints.points.first.flatMap { loadpoints.level($0) }
        let reading = NowFlow.readings(
            fields: fields,
            freshness: { site.freshness(fid: $0) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !loadpoints.points.isEmpty
        ).first { $0.node == node }
        VStack(alignment: .leading, spacing: 8) {
            if let reading {
                HeroLine(reading: reading).equatable()
                HeroFreshness(freshness: worst(reading.freshness, sources.devices[node] ?? []))
                if let devices = sources.split(node) {
                    DeviceRows(site: site, devices: devices, readAtMs: sources.readAtMs, tint: Theme.color(reading.tone))
                }
            } else {
                Text(L("Your box sends no reading for this."))
                    .font(.headline)
                    .foregroundStyle(Theme.fgDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The node is only as live as its least live device. The box names one
    /// source per field; the devices behind the node, once read, may say more.
    private func worst(_ f: NodeFreshness, _ devices: [SourcesModel.Device]) -> NodeFreshness {
        // A device the stream does not name says nothing either way.
        let states = devices.filter { site.session.sources[$0.name] != nil }.map { site.deviceFreshness($0.name) }
        guard let bad = states.filter({ !$0.live }).max(by: { $0.srcState < $1.srcState }), f.live else { return f }
        return bad
    }
}

private struct HeroLine: View, Equatable {
    let reading: NodeReading

    var body: some View {
        let live = reading.freshness.live
        let color = live ? Theme.color(reading.tone) : Theme.fgMuted
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: NodeLook.symbol(reading.node, levelPct: reading.levelPct, flowing: reading.flowing))
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 34)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                NodeValue(watts: reading.watts, size: 34)
                    .foregroundStyle(live ? Theme.fg : Theme.fgMuted)
                Text(reading.word)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            if let level = reading.levelPct {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(AppWords.percent(level))
                        .font(Theme.percent(.title2, weight: .bold))
                        .foregroundStyle(reading.levelAssumed ? Theme.fgMuted : Theme.fg)
                        .contentTransition(.numericText(value: level))
                    LevelBar(pct: level, assumed: reading.levelAssumed, tint: reading.node == .car ? Theme.mobility : Theme.storage, showsFigure: false)
                    if reading.levelAssumed {
                        Text(L("FTW assumes")).font(.caption2).foregroundStyle(Theme.fgMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(Theme.spring, value: reading.word)
        .accessibilityElement(children: .combine)
    }
}

private struct HeroFreshness: View {
    let freshness: NodeFreshness

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(freshness.live ? Theme.freshLive : freshness.srcState == .never ? Theme.fgMuted : Theme.freshStale)
                .frame(width: 7, height: 7)
            Text(line)
                .font(.footnote)
                .foregroundStyle(freshness.live ? Theme.fgDim : Theme.generation)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Live · sungrow", or how old and why not live.
    private var line: String {
        let name = freshness.sourceName.map { " · \($0)" } ?? ""
        if freshness.live { return L("Live") + name }
        if freshness.carrier == .cache { return NodeWords.format("Saved on this phone, %@", NodeLook.age(freshness)) + name }
        switch freshness.srcState {
        case .never: return L("No reading yet") + name
        case .down: return NodeWords.format("Not reporting, %@", NodeLook.age(freshness)) + name
        default: return NodeWords.format("Not live, %@", NodeLook.age(freshness)) + name
        }
    }
}

/// Each device behind a node, for a home with more than one: one line
/// while they fit side by side, a line each when they do not.
private struct DeviceRows: View {
    let site: SiteModel
    let devices: [SourcesModel.Device]
    let readAtMs: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { chips }
                VStack(alignment: .leading, spacing: 4) { chips }
            }
            if let readAtMs, site.nowMs - readAtMs > 30_000 {
                Text(NodeWords.format("Split read at %@", AppWords.clock(readAtMs, zone: .current)))
                    .font(.caption2)
                    .foregroundStyle(Theme.fgMuted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .animation(Theme.spring, value: devices)
    }

    @ViewBuilder private var chips: some View {
        ForEach(devices) { d in
            let f = site.deviceFreshness(d.name)
            HStack(spacing: 6) {
                Circle().fill(f.live ? Theme.freshLive : Theme.freshStale).frame(width: 6, height: 6)
                Text(d.name).font(.footnote.weight(.medium)).foregroundStyle(Theme.fg)
                Text(AppWords.power(d.watts))
                    .font(Theme.number(13, weight: .semibold))
                    .foregroundStyle(f.live ? tint : Theme.fgMuted)
                    .contentTransition(.numericText(value: d.watts))
                if let level = d.levelPct {
                    Text(AppWords.percent(level)).font(Theme.percent(.footnote)).foregroundStyle(Theme.fgDim)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Live

private struct LiveSection: View {
    let site: SiteModel
    let trace: LiveTrace
    let node: EnergyNode

    var body: some View {
        let now = site.nowMs
        let points = trace.points(node.fid, sinceMs: now - LiveTrace.windowMs).map { LiveTrace.Point(t: $0.t, v: node.shown($0.v)) }
        let live = site.freshness(node).live
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Kicker(L("Live · last 5 min"))
                Spacer()
                DirectionKey(node: node)
            }
            if points.count < 2 {
                Text(live ? L("Drawing as readings arrive…") : L("No live readings while your box is out of reach."))
                    .font(.footnote)
                    .foregroundStyle(Theme.fgMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveChart(points: points, nowMs: now, color: live ? Theme.color(NodeLook.tone(node)) : Theme.fgMuted, signed: NodeLook.signed(node))
                    .equatable()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Which way is up, for a node whose curve crosses zero.
private struct DirectionKey: View {
    let node: EnergyNode

    var body: some View {
        if let words = node.directions {
            HStack(spacing: 8) {
                Label(words.up, systemImage: "arrow.up")
                Label(words.down, systemImage: "arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(Theme.fgDim)
            .lineLimit(1)
        }
    }
}

// MARK: Today, two days, ahead

private struct PeriodSection: View {
    let site: SiteModel
    let node: EnergyNode
    let period: NodeView.Period
    let models: NodeModels
    let prices: PriceModel
    let loadpoints: LoadpointsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch period {
                case .today, .twoDays: past
                case .ahead: ahead
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(Theme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        .animation(Theme.spring, value: period)
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
                CarHoursChart(hours: models.carEnergy.hours, fromMs: fromMs, toMs: toMs, strideHours: stride).equatable()
            } else {
                Placeholder(text: models.carEnergy.problem)
            }
        } else if !models.history.available {
            Placeholder(text: L("Your box keeps no history."))
        } else if models.history.frame != nil {
            HistoryChart(samples: models.history.samples(node, fromMs: fromMs), fromMs: fromMs, toMs: toMs, color: Theme.color(NodeLook.tone(node)), signed: NodeLook.signed(node), strideHours: stride)
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
                    bars: slots.map { AheadChart.Bar(startMs: $0.startMs, endMs: $0.endMs, watts: node == .battery ? $0.batteryW : $0.gridW) },
                    prices: slots.compactMap { s in s.priceMinor.map { AheadChart.Price(startMs: s.startMs, endMs: s.endMs, minor: $0) } },
                    currency: window?.currency ?? "SEK",
                    nowMs: now,
                    color: Theme.color(NodeLook.tone(node)),
                    outColor: NodeLook.outColor(node),
                    signed: true
                ).equatable()
            }
        case .solar, .home:
            let slots = models.plan.forecastAhead(nowMs: now)
            if slots.isEmpty {
                Placeholder(text: models.plan.forecastLoaded ? L("No forecast for the hours ahead yet.") : nil)
            } else {
                AheadChart(
                    bars: slots.map { AheadChart.Bar(startMs: $0.startMs, endMs: $0.startMs + $0.durationMs, watts: node == .solar ? $0.pvW : $0.loadW) },
                    prices: slots.compactMap { s in s.priceMinor.map { AheadChart.Price(startMs: s.startMs, endMs: s.startMs + s.durationMs, minor: $0) } },
                    currency: window?.currency ?? "SEK",
                    nowMs: now,
                    color: Theme.color(NodeLook.tone(node)),
                    outColor: Theme.color(NodeLook.tone(node)),
                    signed: false
                ).equatable()
            }
        case .car:
            let windows = loadpoints.points.flatMap { loadpoints.windows[$0.id] ?? $0.planWindows }
            AheadChart(
                bars: windows.filter { $0.toMs > now }.map { w in
                    // A window that names no peak is drawn at its mean.
                    AheadChart.Bar(startMs: w.fromMs, endMs: w.toMs, watts: w.peakW ?? (w.energyWh ?? 0) * 3_600_000 / max(1, w.toMs - w.fromMs))
                },
                prices: priceBars,
                currency: window?.currency ?? "SEK",
                nowMs: now,
                color: Theme.mobility,
                outColor: Theme.mobility,
                signed: false
            ).equatable()
        }
    }

    /// One sentence under the chart: the energy in kWh, or the plan.
    private var summary: String {
        let zone = TimeZone.current
        switch period {
        case .today, .twoDays:
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
            switch node {
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
                Text(text).font(.footnote).foregroundStyle(Theme.fgMuted).multilineTextAlignment(.center)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surfaceSunken)
                    .redacted(reason: .placeholder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: The mode

private struct ModeSection: View {
    let mode: ModeModel
    let node: EnergyNode
    let choose: () -> Void

    var body: some View {
        let key = mode.shown
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker(L("Mode"))
                    Text(mode.label ?? "—")
                        .font(.headline)
                        .foregroundStyle(Theme.fg)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                if mode.canControl {
                    Button(L("Change"), action: choose)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("node.mode.change")
                }
            }
            if let outcome = mode.outcome {
                ReceiptView(outcome: outcome)
            } else {
                Text(ModeWords.isPlan(key) ? (mode.shownStyle.map { L($0.help) } ?? ModeWords.help(mode.info(key))) : ModeWords.help(mode.info(key)))
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        .animation(Theme.spring, value: mode.outcome)
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in Self.feedback(tone) }
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

/// The car's own mode is its charging: what it does now, and the way into
/// the car view for the goal, the level and Charge now.
private struct CarLink: View {
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID

    var body: some View {
        if let lp = loadpoints.points.first {
            NavigationLink(value: HomeRoute.car(lp.id)) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Kicker(L("Charging"))
                        Text(EVText.status(lp, zone: loadpoints.zone))
                            .font(.headline)
                            .foregroundStyle(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("Goal, level and Charge now"))
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.fgMuted)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: HomeRoute.car(lp.id), in: zoom)
            .accessibilityIdentifier("node.car.open")
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

    /// Below the line: the battery giving power, the home selling.
    static func outColor(_ node: EnergyNode) -> Color {
        switch node {
        case .battery: return Theme.generation
        case .grid: return Theme.exporting
        default: return Theme.color(tone(node))
        }
    }

    static func signed(_ node: EnergyNode) -> Bool { node == .battery || node == .grid }

}
