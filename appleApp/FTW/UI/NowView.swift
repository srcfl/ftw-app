import FTWKit
import SwiftUI

/// Now, the first screen, kept to what is looked at every day: whether FTW
/// is in control, the house, the car and the price.
struct NowView: View {
    let app: AppModel
    let home: HomeModels
    let openCar: (String) -> Void

    private var site: SiteModel { home.site }

    var body: some View {
        Group {
            switch site.session.phase {
            case .booting:
                Title(L("Your box is starting"))
                Text(L("This can take a few minutes after an update. Nothing is wrong. Your home appears here when it is ready."))
                if let boot = site.session.boot {
                    Hint("\(Self.bootWords(boot.phase)) · \(boot.pct)%")
                }
            case .terminated:
                Title(L("Access ended"))
                Text(site.session.terminated == .revoked ? L("Your access to this home was withdrawn by its owner.") : L("This session ended."))
                if site.session.terminated == .revoked {
                    Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
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
        }
        .onDisappear {
            home.status.deactivate()
            home.prices.deactivate()
        }
    }

    /// Paired, and not one reading has ever arrived. A hollow house would
    /// read as a home at zero, so this says what is true instead.
    @ViewBuilder private var nothingYet: some View {
        Title(L("Nothing from your box yet"))
        Text(app.connectHelp ?? L("This phone is paired to it and keeps trying on its own. Your home appears here as soon as the box answers."))
        if app.connectHelp != nil {
            Button(L("Get this phone back in")) { app.recovering = true }.buttonStyle(.primary)
        } else if !app.isDemo {
            Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
        }
    }

    // MARK: The house

    private var live: Bool { site.isLive }

    private var chargeW: Double {
        home.loadpoints.stale ? 0 : Flow.loadpointChargeW(home.loadpoints.points)
    }

    private var watchingStatus: Bool {
        site.documentVisible && site.session.phase == .streaming && site.hasPassthrough
    }

    private var statusLive: Bool { home.status.fresh && live && watchingStatus }

    private var readings: Flow.Readings {
        if let status = home.status.status, statusLive || !live {
            return Flow.readings(status: status)
        }
        return Flow.readings(fields: Flow.withLoadpointEV(site.session.fields, evW: chargeW))
    }

    @ViewBuilder private var house: some View {
        if let help = app.connectHelp {
            Card {
                Text(help)
                Button(L("Get this phone back in")) { app.recovering = true }.buttonStyle(.quiet)
            }
        }
        if site.session.needsUpdate {
            Card { Text(L("This app is older than your box. Some things are hidden until it updates.")) }
        }
        InControlRow(answer: InControl.answer(
            live: live,
            lastKnownMs: site.cachedAtMs ?? site.lastFrameAtMs,
            dispatchBlockedBy: site.session.dispatchBlockedBy,
            status: home.status.status,
            statusFresh: statusLive
        ))

        // Motion claims power is flowing right now, so a cached view holds still.
        FlowDiagram(readings: readings, moving: live) { _ in }
        if home.status.status != nil, !statusLive {
            Hint(L(live ? "Device details are out of date. Showing live totals." : "Device details are out of date."))
        }

        if site.heardFromBox {
            ForEach(home.loadpoints.points) { lp in
                CarRow(lp: lp, loadpoints: home.loadpoints) { openCar(lp.id) }
            }
        }

        if let prices = home.prices.prices {
            Card {
                PriceChart(prices: prices, nowMs: site.nowMs, compact: true)
                if home.prices.hasHole {
                    Hint(L("Some hours are missing their price."))
                } else if prices.stale {
                    Hint(L("Tomorrow's rates aren't published yet."))
                }
            }
        }
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

/// "Is FTW in control?" in one calm line. Green only when Core says yes
/// over a live stream; a cache is grey and dated.
struct InControlRow: View {
    let answer: InControl.Answer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Kicker(L("Is FTW in control?"))
                Text(answer.title)
                    .font(.headline)
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = answer.detail {
                    Hint(detail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius)
                .fill(color)
                .frame(width: 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch answer.tone {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .alarm: return "exclamationmark.octagon.fill"
        case .neutral: return "circle.dotted"
        case .stale: return "clock"
        }
    }

    private var color: Color {
        switch answer.tone {
        case .ok: return Theme.exporting
        case .warning: return Theme.generation
        case .alarm: return Theme.importing
        case .neutral, .stale: return Theme.fgMuted
        }
    }
}

/// The car on Now: one row that opens the car view.
struct CarRow: View {
    let lp: Loadpoint
    let loadpoints: LoadpointsModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: lp.pluggedIn ? "bolt.car.fill" : "car.side")
                    .font(.title3)
                    .foregroundStyle(Theme.mobility)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // One text, so it wraps as one line at large sizes.
                    heading
                        .foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.fgDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.fgMuted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Car 20 % FTW assumes".
    private var heading: Text {
        let car = Text(L("Car")).font(.headline)
        guard let level = loadpoints.level(lp) else { return car }
        let pct = Text(AppWords.percent(level.pct)).font(Theme.percent(.headline)).foregroundColor(level.origin == .assumed ? Theme.fgMuted : Theme.fg)
        let origin = Text(EVText.originShort(level, zone: loadpoints.zone)).font(.caption).foregroundColor(Theme.fgDim)
        return Text("\(car)  \(pct)  \(origin)")
    }

    /// What it does now; unplugged, the goal it will meet next time.
    private var line: String {
        if loadpoints.stale, let at = loadpoints.readAtMs {
            return AppWords.format("Last known %@.", AppWords.clock(at, zone: loadpoints.zone))
        }
        if !lp.pluggedIn, let s = lp.schedule {
            return "\(EVText.status(lp)) · \(EVText.goal(s, at: Date(), zone: loadpoints.zone))"
        }
        return EVText.status(lp, zone: loadpoints.zone)
    }
}
