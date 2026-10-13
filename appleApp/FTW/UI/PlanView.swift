import FTWKit
import SwiftUI

/// The plan, opened from Now: today and tomorrow round the plan dial, then
/// each thing the box means to do, when, and why, in the box's own
/// reasons. A finger on the dial scrubs the plan.
struct PlanView: View {
    let app: AppModel
    let home: HomeModels
    @State private var choosingMode = false

    private var models: NodeModels { home.nodes }

    var body: some View {
        FitScreen(spacing: 10) { _ in
            PlanBody(site: home.site, models: models, loadpoints: home.loadpoints, prices: home.prices, chooseMode: { choosingMode = true })
        }
        .navigationTitle(PlanGlance.title)
        .navigationBarTitleDisplayMode(.inline)
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

private struct PlanBody: View {
    let site: SiteModel
    let models: NodeModels
    let loadpoints: LoadpointsModel
    let prices: PriceModel
    let chooseMode: () -> Void

    var body: some View {
        // The plan marks the minute: it redraws once a minute, not a second.
        let minute = (site.nowMs / 60_000).rounded(.down) * 60_000
        let entry = models.planShare.entry
        let moment = PlanGlance.live(entry, nowMs: minute)
        PlanDialCard(
            entry: entry,
            nowMs: minute,
            batteryPct: site.socPercent,
            batteryOld: !site.isLive,
            fetching: prices.fetching,
            summary: moment.summary
        )
        Text(stateLine(moment))
            .font(.footnote)
            .foregroundStyle(moment.state == .boxStale ? Theme.generation : Theme.fgDim)
            .fixedSize(horizontal: false, vertical: true)
        PriceRow(prices: prices, minute: minute)
        Events(moment: moment, entry: models.planShare.entry, loadpoints: loadpoints)
        CompactMode(mode: models.mode, choose: chooseMode)
    }

    /// When the box made it, or that it could not.
    private func stateLine(_ m: PlanGlance.Moment) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs else { return L("Reading the plan from your box…") }
        return NodeWords.format("Planned by your box at %@. It plans again every quarter of an hour.", AppWords.clock(at, zone: .current))
    }
}

/// Each thing the box means to do, when, and why.
private struct Events: View {
    let moment: PlanGlance.Moment
    let entry: PlanEntry
    let loadpoints: LoadpointsModel

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
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func row(_ e: PlanGlance.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DialSwatch(kind: e.kind)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
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
                .font(Theme.number(13, weight: .medium))
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
                        Text("\(Text(AppWords.decimal(PriceStrip.text(current.totalMinor, window.currency))).font(Theme.number(15, weight: .bold)).foregroundStyle(Theme.fg)) \(Text(PriceUnits.unit(window.currency).perKwh).font(.caption2).foregroundStyle(Theme.fgMuted))")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.fgMuted)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
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
                        .foregroundStyle(mode.canControl ? Theme.accent : Theme.fg)
                    if mode.canControl {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
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
