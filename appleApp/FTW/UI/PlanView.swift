import FTWKit
import SwiftUI

/// The plan, opened from Now: the next twelve hours as lanes over the
/// prices, then each thing the box means to do, when, and why, in the
/// box's own reasons. One screen, like Now.
struct PlanView: View {
    let app: AppModel
    let home: HomeModels
    @State private var choosingMode = false

    private var models: NodeModels { home.nodes }

    var body: some View {
        FitScreen(spacing: 10) { fill in
            PlanBody(site: home.site, models: models, loadpoints: home.loadpoints, fill: fill, chooseMode: { choosingMode = true })
        }
        .navigationTitle(PlanGlance.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            models.plan.activate()
            models.mode.activate()
            home.prices.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            models.plan.deactivate()
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
    let fill: Bool
    let chooseMode: () -> Void

    var body: some View {
        // The plan marks the minute: it redraws once a minute, not a second.
        let minute = (site.nowMs / 60_000).rounded(.down) * 60_000
        let moment = PlanGlance.live(models.planShare.entry, nowMs: minute)
        VStack(alignment: .leading, spacing: 4) {
            Text(moment.summary)
                .font(.headline)
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            Text(stateLine(moment))
                .font(.footnote)
                .foregroundStyle(moment.state == .boxStale ? Theme.generation : Theme.fgDim)
        }
        VStack(alignment: .leading, spacing: 6) {
            PlanLanes(moment: moment)
                .equatable()
                .frame(minHeight: fill ? 84 : 140, idealHeight: fill ? 84 : 140, maxHeight: fill ? 200 : 140)
            Legend(kinds: Set(moment.events.map(\.kind)))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
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
            RoundedRectangle(cornerRadius: 2)
                .fill(PlanLanes.color(e.kind))
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
