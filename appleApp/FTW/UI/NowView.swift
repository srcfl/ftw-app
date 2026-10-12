import FTWKit
import SwiftUI

/// Now, the first screen, kept to what is looked at every day: whether FTW
/// is in control, the house, the car and the price.
///
/// Lane 0 drives it. Nothing here asks the box on a timer: the readings
/// arrive on the stream, the price when the day or the published window
/// turns, and the chargers when the screen appears. Each part is its own
/// small view reading only what it shows, so a frame redraws the numbers
/// that moved and nothing else.
struct NowView: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID

    var body: some View {
        NowBody(app: app, home: home, zoom: zoom)
            .onAppear { home.prices.activate() }
            .onDisappear { home.prices.deactivate() }
    }
}

private struct NowBody: View {
    let app: AppModel
    let home: HomeModels
    let zoom: Namespace.ID

    private var site: SiteModel { home.site }

    var body: some View {
        switch site.session.phase {
        case .booting:
            Title(L("Your box is starting"))
            Text(L("This can take a few minutes after an update. Nothing is wrong. Your home appears here when it is ready."))
            if let boot = site.session.boot {
                Hint("\(boot.pct)%")
            }
        case .terminated:
            Title(L("Access ended"))
            Text(site.session.terminated == .revoked ? L("Your access to this home was withdrawn by its owner.") : L("This session ended."))
            if site.session.terminated == .revoked {
                Button(L("Your box won't let this phone in?")) { app.recovering = true }.buttonStyle(.quiet)
            }
        default:
            if !site.session.fields.isEmpty {
                house
            } else if app.isDemo {
                // The demo's first reading is a moment away: the shape of the
                // screen, not a sentence about waiting.
                InControlRow(answer: InControl.Answer(tone: .neutral, title: L("Starting the demo"), detail: L("Live demo · simulated home")))
                    .redacted(reason: .placeholder)
            } else {
                nothingYet
            }
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
        InControlSection(site: site)
        FlowSection(site: site, loadpoints: home.loadpoints)
        if site.heardFromBox || home.loadpoints.fromCache {
            CarSection(loadpoints: home.loadpoints, zoom: zoom)
        }
        PriceSection(site: site, prices: home.prices)
    }
}

// MARK: Is FTW in control?

private struct InControlSection: View {
    let site: SiteModel

    var body: some View {
        InControlRow(answer: InControl.answer(
            streaming: site.isLive,
            lastKnownMs: site.cachedAtMs ?? site.lastFrameAtMs,
            dispatchBlockedBy: site.session.dispatchBlockedBy,
            sources: site.session.sources
        ))
        .equatable()
        .onAppear { LaunchClock.mark("first content") }
    }
}

/// "Is FTW in control?" in one calm line. Green only while frames arrive
/// and the box says nothing blocks it; a cache is grey and dated.
struct InControlRow: View, Equatable {
    let answer: InControl.Answer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: answer.tone)
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
        .animation(Theme.spring, value: answer)
        .accessibilityElement(children: .combine)
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
        case .ok: return Theme.exporting
        case .warning: return Theme.generation
        case .neutral, .stale: return Theme.fgMuted
        }
    }
}

// MARK: The house

private struct FlowSection: View {
    let site: SiteModel
    let loadpoints: LoadpointsModel

    var body: some View {
        // The stream carries the car's watts; a box that leaves them out
        // gets the charger's last answer.
        let evW = loadpoints.stale ? 0 : Flow.loadpointChargeW(loadpoints.points)
        // Motion claims power is flowing right now, so a cached view holds still.
        FlowDiagram(readings: Flow.readings(fields: Flow.withLoadpointEV(site.session.fields, evW: evW)), moving: site.isLive)
            .equatable()
    }
}

// MARK: The car

private struct CarSection: View {
    let loadpoints: LoadpointsModel
    let zoom: Namespace.ID

    var body: some View {
        ForEach(loadpoints.points) { lp in
            NavigationLink(value: HomeRoute.car(lp.id)) {
                CarRow(lp: lp, loadpoints: loadpoints)
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: lp.id, in: zoom)
        }
    }
}

/// The car on Now: one row that opens the car view.
struct CarRow: View {
    static let firstID = "car"

    let lp: Loadpoint
    let loadpoints: LoadpointsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lp.pluggedIn ? "bolt.car.fill" : "car.side")
                .font(.title3)
                .foregroundStyle(Theme.mobility)
                .symbolEffect(.pulse, options: .repeating, isActive: lp.powerW >= 100 && !loadpoints.stale)
                .contentTransition(.symbolEffect(.replace))
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
                    .contentTransition(.numericText())
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
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .animation(Theme.spring, value: lp)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Car 20 % FTW assumes".
    private var heading: Text {
        let car = Text(L("Car")).font(.headline)
        guard let level = loadpoints.level(lp) else { return car }
        let pct = Text(AppWords.percent(level.pct)).font(Theme.percent(.headline)).foregroundStyle(level.origin == .assumed ? Theme.fgMuted : Theme.fg)
        let origin = Text(EVText.originShort(level, zone: loadpoints.zone)).font(.caption).foregroundStyle(Theme.fgDim)
        return Text("\(car)  \(pct)  \(origin)")
    }

    /// What it does now; unplugged, the goal it will meet next time. From
    /// the cache or a lost stream, when the box last said so.
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

// MARK: The price

private struct PriceSection: View {
    let site: SiteModel
    let prices: PriceModel

    var body: some View {
        if let window = prices.prices {
            // The chart marks the minute, not the second: it redraws once a
            // minute however often the clock ticks.
            let minute = (site.nowMs / 60_000).rounded(.down) * 60_000
            Card {
                PriceChart(prices: window, nowMs: minute, compact: true)
                    .equatable()
                if prices.hasHole {
                    Hint(L("Some hours are missing their price."))
                } else if window.stale {
                    Hint(L("Tomorrow's rates aren't published yet."))
                }
            }
        }
    }
}
