import FTWKit
import SwiftUI

/// The shell: pairing when there is nothing to show, else one home. Paints
/// from what is on the phone and never waits on the network.
struct RootView: View {
    let app: AppModel

    var body: some View {
        Group {
            if app.needsPairing {
                // A new link is a new offer, and gets a fresh screen.
                PairView(app: app)
                    .id(app.offeredLink ?? "")
            } else if let home = app.home {
                HomeView(app: app, home: home)
            }
        }
        .background(Theme.surface.ignoresSafeArea())
        .tint(Theme.accent)
    }
}

enum HomeTab: String, Hashable {
    case now

    /// Where a home opens. Debug builds take `-FTWTab now` and the like, so
    /// CI can photograph every screen of the demo.
    static var initial: HomeTab {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "FTWTab").flatMap(HomeTab.init(rawValue:)) ?? .now
        #else
        return .now
        #endif
    }
}

struct HomeView: View {
    let app: AppModel
    let home: HomeModels
    @State private var tab: HomeTab = .initial

    var body: some View {
        VStack(spacing: 0) {
            if app.isDemo {
                DemoBand(site: home.site) { app.exitDemo() }
            } else {
                FreshnessBandView(band: home.site.freshness(noCarrier: app.connectHelp != nil), frameAtMs: home.site.lastFrameAtMs)
            }
            ChargingNotice(site: home.site, charging: home.charging)
            // The car view is the next tab here.
            TabView(selection: $tab) {
                Tab("Now", systemImage: "house", value: HomeTab.now) {
                    Screen(app: app) {
                        NowView(app: app, home: home)
                    }
                }
            }
        }
        .onAppear { home.charging.activate() }
        .onDisappear { home.charging.deactivate() }
    }
}

/// One tab's scrolling page, with pull to refresh.
private struct Screen<Content: View>: View {
    let app: AppModel
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.surface)
        .refreshable { await app.refresh() }
    }
}

/// The one place freshness is said. Above every screen, never scrolled away.
struct FreshnessBandView: View {
    let band: Freshness.Band
    let frameAtMs: Double?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .phaseAnimator([false, true], trigger: frameAtMs) { dot, beat in
                    dot.scaleEffect(band.tone == .live && beat ? 1.5 : 1)
                } animation: { _ in .easeOut(duration: 0.3) }
            Text(band.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let wait = band.wait {
                Text(wait)
                    .font(Theme.number(12, weight: .regular))
                    .foregroundStyle(Theme.fgMuted)
                    .accessibilityHidden(true)
            }
            if let age = band.age {
                Text(age)
                    .font(Theme.number(12, weight: .regular))
                    .foregroundStyle(age == "—" ? Theme.fgMuted : Theme.fgDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surfaceSunken.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch band.tone {
        case .live: return Theme.freshLive
        case .stale: return Theme.freshStale
        case .reaching, .lost: return Theme.freshLost
        case .busy: return Theme.freshStale
        }
    }
}

/// The demo says it is a demo, everywhere, and offers the way out.
struct DemoBand: View {
    let site: SiteModel
    let exit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(site.session.phase == .streaming ? Theme.accent : Theme.fgMuted)
                .frame(width: 8, height: 8)
            Text(site.session.phase == .streaming ? "Live demo · simulated home" : "Starting the demo")
                .font(.footnote.weight(.medium))
            Spacer()
            Button("Exit demo", action: exit)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.quiet)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surfaceSunken.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// A car on the cable, said once above every screen. Only what the box
/// said, and dated when it is out of date.
struct ChargingNotice: View {
    let site: SiteModel
    let charging: ChargingWatch

    var body: some View {
        let fresh = charging.fresh && site.session.phase == .streaming
        ForEach(site.heardFromBox ? charging.points.filter(\.pluggedIn) : []) { lp in
            let current = fresh && lp.charger?.available != false
            VStack(alignment: .leading, spacing: 4) {
                Text(current ? "Car connected" : "Car status is out of date")
                    .font(.subheadline.weight(.semibold))
                Hint(current ? EVText.status(lp, canControl: site.canConfigure) : "Waiting for current charger status. The last reading cannot confirm charging.", tone: Theme.fg)
                if current, let plan = EVText.plan(lp, nowMs: site.nowMs, canControl: site.canConfigure) {
                    Hint(plan)
                }
                if lp.manualSaveError { Hint(EVText.manualSaveErrorText) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised)
            .overlay(alignment: .leading) { Theme.mobility.frame(width: 3) }
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        }
    }
}
