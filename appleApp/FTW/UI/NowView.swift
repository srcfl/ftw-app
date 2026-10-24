import FTWKit
import SwiftUI

/// Now, the first screen, read at a glance and never scrolled: the energy
/// flowing through the home right now, and what comes next. The title is
/// the home's name, the status line under it says whether this is now and
/// who controls the home, and the mode sits beside it. Every node of the
/// flow opens its own view; the plan opens the plan, and its price the
/// price.
///
/// One fixed page, laid out from the height of the screen (`NowLayout`):
/// the plan holds the foot, the flow gets a share of the room above it and
/// sits in its middle, and the plan's price row takes a share of what the
/// flow leaves. Each part keeps its size whatever arrives, so nothing
/// moves when the box answers. At the accessibility sizes each node gets a
/// row of its own instead, so its figure can grow with the text.
///
/// Lane 0 drives it. Nothing here asks the box on a timer: the readings
/// arrive on the stream, the price when the day or the published window
/// turns. Each part is its own small view reading only what it shows, so a
/// frame redraws the numbers that moved and nothing else.
struct NowView: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID
    @Environment(\.dynamicTypeSize) private var typeSize

    private var site: SiteModel { home.site }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.ground)
            // The first content is the first reading on screen, from the
            // cache or the box, not the bare shape before it.
            .onChange(of: site.session.fields.isEmpty, initial: true) { _, empty in
                if !empty { LaunchClock.mark("first content") }
            }
            .onAppear {
                home.prices.activate()
                home.nodes.mode.activate()
                home.nodes.plan.activate()
            }
            .onDisappear {
                home.prices.deactivate()
                home.nodes.mode.deactivate()
                home.nodes.plan.deactivate()
            }
    }

    @ViewBuilder private var content: some View {
        switch site.session.phase {
        case .booting:
            Notice(title: L("Your box is starting"), text: L("This can take a few minutes after an update. Nothing is wrong. Your home appears here when it is ready."), hint: site.session.boot.map { "\($0.pct)%" })
        case .terminated:
            Notice(title: L("Access ended"), text: site.session.terminated == .revoked ? L("Your access to this home was withdrawn by its owner.") : L("This session ended.")) {
                if site.session.terminated == .revoked {
                    Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
                }
            }
        default:
            if typeSize.isAccessibilitySize {
                NowList(app: app, home: home, zoom: zoom)
            } else {
                NowPage(app: app, home: home, zoom: zoom)
            }
        }
    }
}

/// The fixed page. The plan holds the foot at a height that does not
/// depend on what the plan says; the flow is placed in the room above.
private struct NowPage: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        NowColumn {
            FlowSection(site: home.site, loadpoints: home.loadpoints, zoom: zoom, canCommand: home.site.canConfigure && home.site.heardFromBox)
            PlanSlot(app: app, home: home, zoom: zoom)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: 640)
    }
}

/// Places Now's two parts by `NowLayout`: the plan at the foot, at its
/// least height plus what its price row grows by, and the flow centred in
/// the room above. The plan's least height is the same whatever it says,
/// so the places come from the screen and the home's shape alone.
private struct NowColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let flow = subviews[0], plan = subviews[1]
        let least = plan.sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height
        let layout = NowLayout(room: bounds.height - least, least: flow[FlowLeast.self])
        plan.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(width: bounds.width, height: least + layout.grow))
        flow.place(at: CGPoint(x: bounds.minX, y: bounds.minY + layout.above), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: layout.flow))
    }
}

/// The height the home's shape needs, from the flow to the page's layout.
private struct FlowLeast: LayoutValueKey {
    static let defaultValue = NowLayout.minFlow
}

/// The accessibility sizes: a row per node, then the plan. Only here may Now
/// scroll, since a figure that grows with the text needs the room.
private struct NowList: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NodeList(readings: FlowSection.readings(site: home.site, loadpoints: home.loadpoints), zoom: zoom)
                PlanSlot(app: app, home: home, zoom: zoom)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A screen with nothing to draw yet but a sentence: the box starting, or
/// access ended.
private struct Notice<Actions: View>: View {
    let title: String
    let text: String
    var hint: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title(title)
            Text(text)
            if let hint { Hint(hint) }
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 640, alignment: .leading)
    }
}

extension Notice where Actions == EmptyView {
    init(title: String, text: String, hint: String? = nil) {
        self.init(title: title, text: text, hint: hint) { EmptyView() }
    }
}

/// The foot of Now: the plan, or, on a phone that has never heard from its
/// box, what is true about that once the wait has run out. The plan's
/// shape holds the room either way, so the flow above never moves.
private struct PlanSlot: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID

    private var site: SiteModel { home.site }

    /// Paired, never a reading, and the app has stopped expecting one soon.
    private var nothingYet: Bool {
        guard !app.isDemo, site.session.fields.isEmpty else { return false }
        return app.connectHelp != nil || site.freshness(noCarrier: false).tone == .lost
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 18) {
                NowCarRow(home: home, zoom: zoom)
                PlanSection(site: site, models: home.nodes, prices: home.prices, loadpoints: home.loadpoints, zoom: zoom)
            }
                .opacity(nothingYet ? 0 : 1)
                .allowsHitTesting(!nothingYet)
                .accessibilityHidden(nothingYet)
            if nothingYet {
                NothingYet(app: app)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: nothingYet)
    }
}

/// The car under the ring: its goal and its level, and a door into the
/// car's view. Only on a box that keeps cars and knows one; on a box that
/// does not, the charger stays in the ring's corner and this row is not
/// there, so the page's shape is the home's, never the data's.
private struct NowCarRow: View {
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        let cars = home.cars
        if cars.keepsCars, let car = cars.ordered.first {
            let site = home.site, zone = home.loadpoints.zone
            let now = site.minuteMs
            let level = cars.level(car)
            let goal = car.goal.map { CarsModel.schedule($0, nowMs: now, zone: zone) }
            let title = goal.map { "\(car.shownName) · \(EVText.goal($0, at: Date(timeIntervalSince1970: now / 1000), zone: zone))" } ?? car.shownName
            let detail = level.map { "\(CarText.percent($0)) · \(CarText.origin($0, nowMs: now, zone: zone))" } ?? C("Level unknown")
            NavigationLink(value: HomeRoute.car(car.id)) {
                HStack(spacing: 12) {
                    Image(systemName: cars.charger(of: car)?.pluggedIn == true ? "bolt.car.fill" : "car.side.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.car)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(level?.guessed == true ? Theme.ink3 : Theme.ink2)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: HomeRoute.car(car.id), in: zoom)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("now.car")
        }
    }
}

/// Paired, and not one reading has ever arrived. A hollow house would
/// read as a home at zero, so this says what is true instead.
private struct NothingYet: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Nothing from your box yet"))
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(app.connectHelp ?? L("This phone is paired to it and keeps trying on its own. Your home appears here as soon as the box answers."))
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                RetryButton(app: app)
                Button(L("Your box won't let this phone in?")) { app.recovering = true }
                    .buttonStyle(.quiet)
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("now.nothingYet")
    }
}

// MARK: The flow

/// The flow in the height the page gives it, from the room and the home's
/// shape (`NowLayout`), which the node set fixes from the cache on frame
/// one.
private struct FlowSection: View {
    let site: SiteModel
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID
    let canCommand: Bool

    /// What the drawing shows: the stream's readings, the cached home's
    /// nodes before the first one, or the bare shape of a home on a phone
    /// that has never heard from its box.
    @MainActor
    static func readings(site: SiteModel, loadpoints: LoadpointsModel) -> [NodeReading] {
        if site.session.fields.isEmpty, (site.kept?.nodes ?? []).isEmpty { return NowFlow.skeleton }
        // The stream carries the car's watts; a box that leaves them out
        // gets the charger's last answer, with its age.
        return NowFlow.readings(site: site, loadpoints: loadpoints)
    }

    var body: some View {
        let readings = Self.readings(site: site, loadpoints: loadpoints)
        FlowDiagram(readings: readings, zoom: zoom, car: carActions)
            // A drawing with fixed places: its figures grow with the text
            // to the largest standard size, its names stop at the default
            // one. Capped here, so the drawing's scaled sizes see the cap.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .layoutValue(key: FlowLeast.self, value: FlowPlan.least(readings.map(\.node)))
            .sensoryFeedback(trigger: carPoint.flatMap { loadpoints.outcome(hold: $0)?.tone }) { _, tone in ModeSheet.feedback(tone) }
    }

    /// The charger with a car in it, else the first.
    private var carPoint: Loadpoint? {
        loadpoints.points.first { $0.pluggedIn } ?? loadpoints.points.first
    }

    private var carActions: CarActions? {
        guard canCommand, let lp = carPoint, lp.pluggedIn, !loadpoints.holdSending(lp) else { return nil }
        let paused = EVText.isPaused(lp)
        let holding = lp.manualActive && !paused
        let model = loadpoints
        return CarActions(
            chargeNow: holding ? nil : { Task { await model.chargeNow(lp) } },
            pause: paused ? nil : { Task { await model.pause(lp) } },
            backToPlan: holding || paused ? { Task { await model.backToPlan(lp) } } : nil
        )
    }
}

/// Now's nodes as rows, for the largest text: the home first, then each
/// node with its figure, its word and how full. A node that is not live is
/// drawn in ink. Each row is the same door as its bubble.
private struct NodeList: View {
    let readings: [NodeReading]
    let zoom: Namespace.ID
    /// The figure grows with the text, the way the drawing's cannot.
    @ScaledMetric(relativeTo: .title) private var figure: CGFloat = 28

    var body: some View {
        let ordered = readings.filter { $0.node == .home } + readings.filter { $0.node != .home }
        VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().overlay(Theme.line) }
                NavigationLink(value: HomeRoute.node(r.node)) {
                    row(r)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: HomeRoute.node(r.node), in: zoom)
                .accessibilityIdentifier("now.node.\(r.node.rawValue)")
            }
        }
    }

    private func row(_ r: NodeReading) -> some View {
        let live = r.freshness.live
        let color = live ? Theme.color(r.tone) : Theme.fgMuted
        return VStack(alignment: .leading, spacing: 2) {
            Label {
                // One word on one line: smaller before it breaks.
                Text(r.node.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fgDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } icon: {
                Image(systemName: NodeLook.symbol(r.node, levelPct: r.levelPct, flowing: r.flowing)).foregroundStyle(color)
            }
            NodeValue(watts: r.watts, size: figure)
                .foregroundStyle(r.watts == nil ? Theme.fgMuted : (r.node == .home ? Theme.fg : color))
            Text(r.word).font(.body).foregroundStyle(Theme.fgDim)
            if let level = r.levelPct {
                Text(AppWords.percent(level)).font(Theme.percent(.body)).foregroundStyle(r.levelAssumed ? Theme.fgMuted : Theme.fg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r.node.title)
        .accessibilityValue(NodeLook.spoken(r))
        .accessibilityHint(L("Opens live readings, history and the plan."))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: The plan, with the price under it

private struct PlanSection: View {
    let site: SiteModel
    let models: NodeModels
    let prices: PriceModel
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID

    var body: some View {
        // The plan marks the minute, not the second: it redraws once a
        // minute however often the clock ticks.
        let minute = site.minuteMs
        let window = prices.prices
        let current = window.flatMap { w in w.slots.first { minute >= $0.startMs && minute < $0.startMs + $0.durationMs } }
        let shown = models.planShare.shown(nowMs: minute)
        let hasCar = !loadpoints.points.isEmpty
        let strip = PlanStrip.build(shown.entry, moment: shown.moment, hasCar: hasCar)
        PlanStripView(
            strip: strip,
            sentence: shown.moment.nextText,
            shorter: shown.moment.nextShorter,
            placeholder: shown.moment.placeholder,
            priceNow: current.map { PriceStrip.whole($0.totalMinor, window?.currency) },
            unit: PriceUnits.unit(window?.currency).label.uppercased(),
            fade: StripFade.make(models.planShare.before, strip: strip, nowMs: minute, hasCar: hasCar),
            zoom: zoom
        )
        .equatable()
        // Capped where it is placed, so the strip's scaled sizes read the
        // cap too.
        .fitCap(.xLarge)
    }
}
