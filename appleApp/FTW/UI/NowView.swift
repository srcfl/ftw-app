import FTWKit
import SwiftUI

/// Now, the first screen. A glance: one sentence at the top, the house
/// under it, then price, what happens next, today and the fuse.
struct NowView: View {
    let app: AppModel
    let home: HomeModels
    let openCharger: (String?) -> Void
    let open: (HomeTab) -> Void
    @State private var liveRole: LiveRole?

    private var site: SiteModel { home.site }

    var body: some View {
        Group {
            switch site.session.phase {
            case .booting:
                Title("Your box is starting")
                Text("This can take a few minutes after an update while it tidies its database. Nothing is wrong. It will appear here as soon as it is ready.")
                if let boot = site.session.boot {
                    Hint("\(Self.bootWords(boot.phase)) · \(boot.pct)%")
                }
            case .terminated:
                Title("Access ended")
                Text(site.session.terminated == .revoked ? "Your access to this home was withdrawn by its owner." : "This session ended.")
                if site.session.terminated == .revoked {
                    Button("Your box won't let this phone in?") { app.recovering = true }.buttonStyle(.quiet)
                }
            default:
                if site.session.fields.isEmpty {
                    nothingYet
                } else {
                    house
                }
            }
        }
        .onAppear {
            home.status.activate()
            home.prices.activate()
            home.plan.activate()
            home.savings.activate()
        }
        .onDisappear {
            home.status.deactivate()
            home.prices.deactivate()
            home.plan.deactivate()
            home.savings.deactivate()
        }
        .sheet(item: $liveRole) { role in
            LiveSheet(site: site, role: role, fields: flowFields)
        }
    }

    /// Paired, and not one reading has ever arrived. A hollow house would
    /// read as a home at zero, so this says what is true instead.
    @ViewBuilder private var nothingYet: some View {
        Title("Nothing from your box yet")
        Text(app.connectHelp ?? "This phone is paired to it and keeps trying on its own. Your house appears here as soon as the box answers.")
        if app.connectHelp != nil {
            Button("Get this phone back in") { app.recovering = true }.buttonStyle(.primary)
        } else if !app.isDemo {
            Button("Your box won't let this phone in?") { app.recovering = true }.buttonStyle(.quiet)
        }
    }

    // MARK: The house

    private var live: Bool { site.isLive }

    private var flowFields: [Int: Double] {
        Flow.withLoadpointEV(site.session.fields, evW: home.charging.chargeW)
    }

    private var watchingStatus: Bool {
        site.documentVisible && site.session.phase == .streaming && site.hasPassthrough
    }

    private var statusLive: Bool { home.status.fresh && live && watchingStatus }

    private var readings: Flow.Readings {
        if let status = home.status.status, statusLive || !live {
            return Flow.readings(status: status)
        }
        return Flow.readings(fields: flowFields)
    }

    @ViewBuilder private var house: some View {
        if let help = app.connectHelp {
            Card {
                Text(help)
                Button("Get this phone back in") { app.recovering = true }.buttonStyle(.quiet)
            }
        }
        if site.session.needsUpdate {
            Card { Text("This app is older than your box. Some things are hidden until it updates.") }
        }
        Text(Explanation.explain(fields: flowFields, dispatchBlockedBy: site.session.dispatchBlockedBy, ceilingW: site.ceilingW).headline)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.fg)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

        // Motion claims power is flowing right now, so a cached view holds still.
        FlowDiagram(readings: readings, moving: live) { role in
            switch role {
            case .ev: openCharger(nil)
            case .grid: if live { liveRole = .grid }
            case .pv: if live { liveRole = .pv }
            case .battery: if live { liveRole = .battery }
            case .load: if live { liveRole = .load }
            }
        }
        if home.status.status != nil, !statusLive {
            Hint("Device details are out of date.\(live ? " Showing live totals." : "")")
        }
        NowOutlook(site: site, home: home, statusLive: statusLive, open: open)
    }

    static func bootWords(_ phase: String) -> String {
        switch phase {
        case "vacuum": return "tidying its records"
        case "migrate": return "bringing its records up to date"
        case "drivers": return "waking the equipment"
        default: return "getting ready"
        }
    }
}

/// Price, what FTW does next, today and the fuse: the rest of a glance.
private struct NowOutlook: View {
    let site: SiteModel
    let home: HomeModels
    let statusLive: Bool
    let open: (HomeTab) -> Void

    var body: some View {
        if let prices = home.prices.prices {
            Card {
                PriceChart(prices: prices, nowMs: site.nowMs, compact: true)
                if home.prices.hasHole {
                    Hint("Some hours are missing their price.")
                } else if prices.stale {
                    Hint("Tomorrow's rates aren't published yet.")
                }
            }
        }
        planCard
        if let today = today {
            todayCard(today)
        }
        if let status = home.status.status, let fuse = Flow.fuse(status: status) {
            fuseCard(fuse)
        }
    }

    private var planCard: some View {
        let brief = PlanText.brief(home.plan.plan, nowMs: site.nowMs, mode: home.plan.actualMode, dispatchBlockedBy: site.session.dispatchBlockedBy, clock: Clock.time)
        return Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Kicker("Automation")
                    Text("What FTW does next").font(.headline)
                }
                Spacer()
                Text(brief.stateLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(brief.tone == .active ? Theme.exporting : brief.tone == .warn ? Theme.generation : Theme.fgDim)
                    .background(Theme.surfaceSunken, in: Capsule())
            }
            Text(brief.action).font(.body.weight(.semibold))
            if let time = brief.time { Hint(time) }
            if let reason = brief.reason { Hint("\(reason).") }
            Hint(brief.constraint, tone: Theme.fgMuted)
            Button("Open full plan →") { open(.plan) }.buttonStyle(.quiet)
        }
    }

    private struct Today {
        let importWh: Double
        let exportWh: Double
        let pvWh: Double
    }

    private var today: Today? {
        guard let t = home.status.status?["energy"]?["today"], t.object != nil else { return nil }
        return Today(importWh: EnergyFormat.wholeWh(t["import_wh"]?.number), exportWh: EnergyFormat.wholeWh(t["export_wh"]?.number), pvWh: EnergyFormat.wholeWh(t["pv_wh"]?.number))
    }

    private func todayCard(_ today: Today) -> some View {
        Card {
            Kicker(statusLive ? "Since midnight" : "Last known")
            Text(statusLive ? "Today" : "Last totals").font(.headline)
            if !statusLive, let at = home.status.receivedAtMs {
                Hint("Energy totals last updated \(Clock.dayAndTime(at)).")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                EnergyTile(label: "Imported", wh: today.importWh, color: Theme.importing)
                EnergyTile(label: "Exported", wh: today.exportWh, color: Theme.exporting)
                EnergyTile(label: "Solar", wh: today.pvWh, color: Theme.generation)
                if let savings = home.savings.periods {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved \(home.prices.currency)").font(.caption).foregroundStyle(Theme.fgDim)
                        if savings.today.available {
                            Text(Savings.compact(savings.today.savedMinor))
                                .font(Theme.number(20))
                                .foregroundStyle(savings.today.savedMinor >= 0 ? Theme.exporting : Theme.importing)
                        } else {
                            Text("—").font(Theme.number(20))
                        }
                        if savings.week.available {
                            Text("\(Savings.compact(savings.week.savedMinor)) this week").font(.caption).italic().foregroundStyle(Theme.fgDim)
                        }
                    }
                }
            }
            Button("Open history →") { open(.history) }.buttonStyle(.quiet)
        }
    }

    private func fuseCard(_ fuse: Flow.Fuse) -> some View {
        Card {
            Kicker(statusLive ? "Live safety" : "Last known")
            Text("Fuse").font(.headline)
            if !statusLive, let at = home.status.receivedAtMs {
                Hint("Fuse readings last updated \(Clock.dayAndTime(at)).")
            }
            if !fuse.phases.isEmpty {
                ForEach(fuse.phases) { phase in
                    FuseBar(label: phase.label, amps: phase.amps, pct: phase.pct, exporting: phase.exporting)
                }
            } else if let fallback = fuse.fallback {
                FuseBar(label: "\(Int(fuse.maxAmps)) A", amps: fallback.amps, pct: fallback.pct, exporting: false)
            }
        }
    }
}

struct EnergyTile: View {
    let label: String
    let wh: Double
    let color: Color

    var body: some View {
        let parts = EnergyFormat.parts(wh)
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.fgDim)
            (Text(parts.text).font(Theme.number(20)) + Text(" \(parts.unit)").font(.caption))
                .foregroundStyle(color)
        }
    }
}

private struct FuseBar: View {
    let label: String
    let amps: Double
    let pct: Double
    let exporting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
                Spacer()
                Text("\(PowerFormat.fixed(abs(amps), 1)) A").font(Theme.number(13))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, pct / 100)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if pct >= 90 { return Theme.importing }
        if pct >= 70 { return Theme.generation }
        return exporting ? Theme.exporting : Theme.storage
    }
}
