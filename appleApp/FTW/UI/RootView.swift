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

/// Where a home can go from Now: each node's own view, and the car.
enum HomeRoute: Hashable {
    /// One charger's car; nil is the first.
    case car(String?)
    /// Live, history, plan and mode for one node of the flow.
    case node(EnergyNode)

    /// Where a home opens. Debug builds take `-FTWTab car` or
    /// `-FTWNode battery` and the like, so every screen of the demo can be
    /// photographed.
    static var initial: [HomeRoute] {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let node = defaults.string(forKey: "FTWNode").flatMap(EnergyNode.init(rawValue:)) { return [.node(node)] }
        return defaults.string(forKey: "FTWTab") == "car" ? [.car(nil)] : []
        #else
        return []
        #endif
    }
}

struct HomeView: View {
    let app: AppModel
    let home: HomeModels
    @State private var path: [HomeRoute] = HomeRoute.initial
    /// A node on Now grows into its own view, and the car into the car view.
    @Namespace private var zoom

    var body: some View {
        VStack(spacing: 0) {
            if app.isDemo {
                DemoBand(site: home.site) { app.exitDemo() }
            } else {
                Band(app: app, site: home.site)
            }
            NavigationStack(path: $path) {
                NowView(app: app, home: home, zoom: zoom)
                    .background(Theme.surface)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: HomeRoute.self) { route in
                        // Each route zooms out of the view that names it as
                        // its source: a node on Now, the car row in the car's
                        // node view.
                        Group {
                            switch route {
                            case .car(let id):
                                CarView(app: app, home: home, id: id)
                            case .node(let node):
                                NodeView(app: app, home: home, node: node, zoom: zoom)
                            }
                        }
                        .navigationTransition(.zoom(sourceID: route, in: zoom))
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

/// One page that fits the screen it is on. While everything fits, nothing
/// scrolls and the parts that can grow (`fill` is true) take the room
/// there is. Only when it cannot fit, at the largest text sizes, does the
/// same page scroll, with each part at its own natural height.
struct FitScreen<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: (_ fill: Bool) -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            page(fill: true)
            ScrollView {
                page(fill: false)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.surface)
    }

    private func page(fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content(fill) }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .top)
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
        // Chrome above every screen: whole words before large letters.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}
