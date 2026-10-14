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

    private var models: NodeModels { home.nodes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlanBody(site: home.site, models: models, loadpoints: home.loadpoints, prices: home.prices, style: style, chooseMode: { choosingMode = true })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .topLeading)
            .frame(maxWidth: .infinity)
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
            ModeSheet(mode: models.mode)
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
    @State private var dials = DialMemo()

    var body: some View {
        // The plan marks the minute: it redraws once a minute, not a second.
        let minute = site.minuteMs
        let moment = models.planShare.moment(nowMs: minute)
        Group {
            switch style {
            case .dial:
                let dial = dials.dial(models.planShare.entry, nowMs: minute)
                VStack(alignment: .leading, spacing: 12) {
                    PlanDialCard(dial: dial, grey: moment.isGrey)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(moment.summary)
                            .font(.subheadline)
                            .foregroundStyle(moment.isGrey ? Theme.ink3 : Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .redacted(reason: moment.placeholder ? .placeholder : [])
                        // Mono stops growing at accessibility1.
                        Group {
                            if let cheapest = dial.cheapestText {
                                Text(cheapest).foregroundStyle(Theme.ink2)
                            }
                            Text(plannedLine(moment, zone: dial.zone))
                                .foregroundStyle(moment.state == .boxStale ? Theme.alarm : Theme.ink3)
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
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PlanLanes(moment: moment)
                            .equatable()
                            .frame(height: 140)
                        Legend(kinds: Set(moment.events.map(\.kind)))
                    }
                }
                .transition(.opacity)
            }
        }
        PriceRow(prices: prices, minute: minute)
        Events(moment: moment, entry: models.planShare.entry, loadpoints: loadpoints, style: style)
        CompactMode(mode: models.mode, choose: chooseMode)
    }

    /// "PLANNED 16:51 · REPLANS EVERY 15 MIN", or that the box could not.
    private func plannedLine(_ m: PlanGlance.Moment, zone: TimeZone) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return PlanDial.planned(atMs: at, old: m.state == .old, zone: zone)
    }

    /// When the box made it, or that it could not.
    private func stateLine(_ m: PlanGlance.Moment) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return NodeWords.format("Planned by your box at %@. It plans again every quarter of an hour.", AppWords.clock(at, zone: m.timeZone))
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

/// The mode in one row, for the plan it decides.
private struct CompactMode: View {
    let mode: ModeModel
    let choose: () -> Void

    var body: some View {
        if let label = mode.label {
            Button(action: choose) {
                HStack {
                    Kicker(L("Mode"))
                    Spacer(minLength: 8)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode.mayControl ? Theme.accent : Theme.fg)
                    if mode.mayControl {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!mode.canControl)
            .accessibilityIdentifier("plan.mode")
        }
    }
}

private extension String {
    /// "Power is cheap · up to 3 kW": a sentence starts with a capital.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
