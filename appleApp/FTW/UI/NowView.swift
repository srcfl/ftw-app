import FTWKit
import SwiftUI

/// Now, the first screen, built to be read at a glance and never scrolled:
/// whether FTW is in control and how the home is run, the energy flowing
/// through the home right now, and what power costs. Every node of the flow
/// opens its own view with live readings, history, the plan and the mode.
///
/// Lane 0 drives it. Nothing here asks the box on a timer: the readings
/// arrive on the stream, the price when the day or the published window
/// turns. Each part is its own small view reading only what it shows, so a
/// frame redraws the numbers that moved and nothing else.
struct NowView: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID
    @State private var choosingMode = false

    var body: some View {
        FitScreen { fill in
            NowBody(app: app, home: home, zoom: zoom, fill: fill, chooseMode: { choosingMode = true })
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
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: home.nodes.mode)
        }
    }
}

private struct NowBody: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID
    let fill: Bool
    let chooseMode: () -> Void

    private var site: SiteModel { home.site }

    var body: some View {
        switch site.session.phase {
        case .booting:
            Title(L("Your box is starting"))
            Text(L("This can take a few minutes after an update. Nothing is wrong. Your home appears here when it is ready."))
            if let boot = site.session.boot {
                Hint("\(boot.pct)%")
            }
            Spacer(minLength: 0)
            AboutLink(app: app)
        case .terminated:
            Title(L("Access ended"))
            Text(site.session.terminated == .revoked ? L("Your access to this home was withdrawn by its owner.") : L("This session ended."))
            if site.session.terminated == .revoked {
                Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
            }
            Spacer(minLength: 0)
            AboutLink(app: app)
        default:
            if !site.session.fields.isEmpty {
                house
            } else if app.isDemo {
                // The demo's first reading is a moment away: the shape of the
                // screen, not a sentence about waiting.
                StatusRow(answer: InControl.Answer(tone: .neutral, title: L("Starting the demo"), detail: nil), mode: nil, canChoose: false, choose: {})
                    .redacted(reason: .placeholder)
                Spacer(minLength: 0)
            } else {
                nothingYet
                Spacer(minLength: 0)
                AboutLink(app: app)
            }
        }
    }

    /// Paired, and not one reading has ever arrived. A hollow house would
    /// read as a home at zero, so this says what is true instead.
    @ViewBuilder private var nothingYet: some View {
        Title(L("Nothing from your box yet"))
        Text(app.connectHelp ?? L("This phone is paired to it and keeps trying on its own. Your home appears here as soon as the box answers."))
        if app.connectHelp != nil {
            // Most of what stops a connect passes: try that first, and keep
            // pairing again as the way back when it does not.
            RetryConnect(app: app)
            Button(L("Get this phone back in")) { app.recovering = true }.buttonStyle(.quiet)
        } else if !app.isDemo {
            Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
        }
    }

    @ViewBuilder private var house: some View {
        if let help = app.connectHelp {
            Card {
                Text(help)
                RetryConnect(app: app)
                Button(L("Get this phone back in")) { app.recovering = true }.buttonStyle(.quiet)
            }
        }
        if site.session.needsUpdate {
            Card { Text(L("This app is older than your box. Some things are hidden until it updates.")) }
        }
        StatusSection(site: site, mode: home.nodes.mode, choose: chooseMode)
        FlowSection(site: site, loadpoints: home.loadpoints, zoom: zoom, fill: fill, canCommand: site.canConfigure)
        PlanSection(site: site, models: home.nodes, prices: home.prices, zoom: zoom)
        AboutLink(app: app)
            .padding(.top, -18)
    }
}

/// Builds the connection again, with Face ID if the key needs it. Pairing
/// again is a separate, later choice.
private struct RetryConnect: View {
    let app: AppModel
    @State private var trying = false

    var body: some View {
        Button {
            trying = true
            Task {
                await app.connect()
                trying = false
            }
        } label: {
            HStack(spacing: 8) {
                if trying { ProgressView().controlSize(.small).tint(Theme.onAccent) }
                Text(L("Try again"))
            }
        }
        .buttonStyle(.primary)
        .disabled(trying)
        .accessibilityIdentifier("now.connect.retry")
    }
}

// MARK: Is FTW in control, and how is the home run?

private struct StatusSection: View {
    let site: SiteModel
    let mode: ModeModel
    let choose: () -> Void

    var body: some View {
        StatusRow(
            answer: InControl.answer(
                streaming: site.isLive,
                lastKnownMs: site.cachedAtMs ?? site.lastFrameAtMs,
                dispatchBlockedBy: site.session.dispatchBlockedBy,
                sources: site.session.sources
            ),
            mode: mode.label.map { ModeLabel(text: $0, sending: mode.sending, doubt: mode.doubt) },
            canChoose: mode.canControl,
            choose: choose
        )
        .equatable()
        .onAppear { LaunchClock.mark("first content") }
    }
}

struct ModeLabel: Equatable {
    let text: String
    let sending: Bool
    /// A change the box took and never confirmed: the box's mode shows,
    /// and this says what was asked.
    var doubt: String?
}

/// "Is FTW in control?" in one calm line, and the mode beside it. Green
/// only while frames arrive and the box says nothing blocks it; a cache is
/// grey and dated. The mode opens its choices for an owner.
struct StatusRow: View, Equatable {
    let answer: InControl.Answer
    let mode: ModeLabel?
    let canChoose: Bool
    let choose: () -> Void

    nonisolated static func == (a: StatusRow, b: StatusRow) -> Bool {
        a.answer == b.answer && a.mode == b.mode && a.canChoose == b.canChoose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row on every iPhone: the mode keeps its width and the answer
            // wraps beside it. Only at the accessibility sizes, where the
            // mode alone is wider than the phone, do the two stack.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    control
                        .frame(maxWidth: .infinity, alignment: .leading)
                    modeView(alignment: .trailing)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    control
                    modeView(alignment: .leading)
                }
            }
            if let doubt = mode?.doubt {
                Label {
                    Text(doubt).foregroundStyle(Theme.fg)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.alarm)
                }
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("now.mode.doubt")
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius)
                .fill(color)
                .frame(width: 4)
        }
        .animation(Theme.spring, value: answer)
        .animation(Theme.spring, value: mode)
        // One calm row on every iPhone at every standard size; the node
        // views and the mode sheet say the same at any size.
        .fitCap(.large)
    }

    private var control: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: answer.tone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Kicker(L("Is FTW in control?"))
                Text(answer.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                // A calm yes needs no second line; anything else says why.
                if answer.tone != .ok, let detail = answer.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func modeView(alignment: HorizontalAlignment) -> some View {
        if let mode {
            Button(action: choose) {
                VStack(alignment: alignment, spacing: 1) {
                    Kicker(L("Mode"))
                    HStack(spacing: 3) {
                        Text(mode.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canChoose ? Theme.accent : Theme.fg)
                            .contentTransition(.opacity)
                            // Beside the answer one line; stacked under it,
                            // as much as the name needs.
                            .lineLimit(alignment == .trailing ? 1 : 3)
                        if mode.sending {
                            ProgressView().controlSize(.mini)
                        } else if canChoose {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canChoose)
            .accessibilityLabel(L("Mode"))
            .accessibilityValue(mode.text)
            .accessibilityHint(canChoose ? L("Change mode") : "")
            .accessibilityIdentifier("now.mode")
        }
    }

    private var symbol: String {
        switch answer.tone {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle.dotted"
        case .stale: return "clock"
        }
    }

    private var color: Color {
        switch answer.tone {
        case .ok: return Theme.live
        case .warning: return Theme.alarm
        case .neutral, .stale: return Theme.fgMuted
        }
    }
}

// MARK: The flow

private struct FlowSection: View {
    let site: SiteModel
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID
    let fill: Bool
    let canCommand: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The stream carries the car's watts; a box that leaves them out
        // gets the charger's last answer.
        let evW = loadpoints.stale ? 0 : Flow.loadpointChargeW(loadpoints.points)
        let fields = Flow.withLoadpointEV(site.session.fields, evW: evW)
        let car = loadpoints.points.first.flatMap { loadpoints.level($0) }
        let readings = NowFlow.readings(
            fields: fields,
            freshness: { site.freshness(fid: $0) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !loadpoints.points.isEmpty
        )
        // The drawing has fixed places and stops growing at xLarge. At the
        // accessibility sizes each node gets a row of its own instead, so
        // its figure can grow with the text.
        if typeSize.isAccessibilitySize {
            NodeList(readings: readings, zoom: zoom)
        } else {
            FlowDiagram(readings: readings, zoom: zoom, car: carActions)
                .frame(minHeight: fill ? 214 : 330, idealHeight: fill ? 214 : 330, maxHeight: fill ? .infinity : 330)
                .sensoryFeedback(trigger: carPoint.flatMap { loadpoints.outcome(hold: $0)?.tone }) { _, tone in ModeSheet.feedback(tone) }
        }
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
/// node with its figure, its word, how full, and how old if not live. Each
/// row is the same door as its bubble.
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
        .padding(.horizontal, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
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
            if !live, r.watts != nil {
                FreshnessTag(freshness: r.freshness)
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
    let zoom: Namespace.ID

    var body: some View {
        // The plan marks the minute, not the second: it redraws once a
        // minute however often the clock ticks.
        let minute = (site.nowMs / 60_000).rounded(.down) * 60_000
        let entry = models.planShare.entry
        let window = prices.prices
        let current = window.flatMap { w in w.slots.first { minute >= $0.startMs && minute < $0.startMs + $0.durationMs } }
        NavigationLink(value: HomeRoute.plan) {
            PlanCard(
                moment: PlanGlance.live(entry, nowMs: minute),
                priceNow: current.map { PriceStrip.text($0.totalMinor, window?.currency) },
                unit: PriceUnits.unit(window?.currency).perKwh
            )
            .equatable()
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: HomeRoute.plan, in: zoom)
        .accessibilityIdentifier("now.plan")
    }
}
