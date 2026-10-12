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
        .onAppear { LaunchClock.mark("first frame") }
    }
}

/// Where a home can go from Now. M1 has one place: the car.
enum HomeRoute: Hashable {
    /// One charger's car; nil is the first.
    case car(String?)

    /// Where a home opens. Debug builds take `-FTWTab car` and the like, so
    /// every screen of the demo can be photographed.
    static var initial: [HomeRoute] {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "FTWTab") == "car" ? [.car(nil)] : []
        #else
        return []
        #endif
    }
}

struct HomeView: View {
    let app: AppModel
    let home: HomeModels
    @State private var path: [HomeRoute] = HomeRoute.initial
    /// The car row on Now grows into the car view.
    @Namespace private var zoom

    var body: some View {
        VStack(spacing: 0) {
            if app.isDemo {
                DemoBand(site: home.site) { app.exitDemo() }
            } else {
                Band(app: app, site: home.site)
            }
            NavigationStack(path: $path) {
                Screen(app: app) {
                    NowView(app: app, home: home, zoom: zoom)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .car(let id):
                        CarView(app: app, home: home, id: id)
                            .navigationTransition(.zoom(sourceID: id ?? CarRow.firstID, in: zoom))
                    }
                }
            }
        }
        // Now and the car read the chargers from one model, so a screen
        // appearing asks the box once.
        .onAppear { home.loadpoints.activate() }
        .onDisappear { home.loadpoints.deactivate() }
    }
}

/// The freshness band, in its own view so a frame redraws the band and not
/// the screen under it.
private struct Band: View {
    let app: AppModel
    let site: SiteModel

    var body: some View {
        FreshnessBandView(band: site.freshness(noCarrier: app.connectHelp != nil), frameAtMs: site.lastFrameAtMs)
    }
}

/// One scrolling page, with pull to refresh.
struct Screen<Content: View>: View {
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
        // One line of chrome above every screen: it must not crowd out the
        // screen at the largest text sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
            Text(L(site.session.phase == .streaming ? "Live demo · simulated home" : "Starting the demo"))
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button(L("Exit demo"), action: exit)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .buttonStyle(.quiet)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surfaceSunken.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
