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
    /// The plan ahead, from Now's plan card.
    case plan

    /// Where a home opens. Debug builds take `-FTWTab car` or
    /// `-FTWNode battery` and the like, so every screen of the demo can be
    /// photographed.
    static var initial: [HomeRoute] {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let node = defaults.string(forKey: "FTWNode").flatMap(EnergyNode.init(rawValue:)) { return [.node(node)] }
        switch defaults.string(forKey: "FTWTab") {
        case "car": return [.car(nil)]
        case "plan": return [.plan]
        default: return []
        }
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
        NavigationStack(path: $path) {
            NowView(app: app, home: home, zoom: zoom)
                .background(Theme.surface)
                .navigationTitle(L("Now"))
                .navigationBarTitleDisplayMode(.inline)
                .freshness(app: app, site: home.site)
                .toolbar {
                    if app.isDemo {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L("Exit demo")) { app.exitDemo() }
                                .accessibilityIdentifier("demo.exit")
                        }
                    }
                }
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
                        case .plan:
                            PlanView(app: app, home: home)
                        }
                    }
                    .freshness(app: app, site: home.site)
                    .navigationTransition(.zoom(sourceID: route, in: zoom))
                }
        }
        // Now and the car read the chargers from one model, so a screen
        // appearing asks the box once.
        .onAppear { home.loadpoints.activate() }
        .onDisappear { home.loadpoints.deactivate() }
    }
}

extension View {
    /// Freshness under every screen's title, in the system's own bar, so it
    /// never scrolls away and needs no band of its own.
    func freshness(app: AppModel, site: SiteModel) -> some View {
        modifier(FreshnessSubtitle(app: app, site: site))
    }
}

private struct FreshnessSubtitle: ViewModifier {
    let app: AppModel
    let site: SiteModel

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .subtitle) {
                FreshnessLine(app: app, site: site)
            }
        }
    }
}

/// "● Live via encrypted relay · 2 s", or the demo's own line, in its own
/// view so a frame redraws this line and not the screen under it. A change
/// of state cross-fades; the dot beats with each frame unless Reduce Motion
/// is on.
struct FreshnessLine: View {
    let app: AppModel
    let site: SiteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let line = self.line
        HStack(spacing: 5) {
            Circle()
                .fill(line.color)
                .frame(width: 7, height: 7)
                .phaseAnimator([false, true], trigger: site.lastFrameAtMs) { dot, beat in
                    dot.scaleEffect(line.beats && beat && !reduceMotion ? 1.4 : 1)
                } animation: { _ in .easeOut(duration: 0.3) }
            Text(line.message)
                .contentTransition(.opacity)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let tail = line.tail {
                Text(tail)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.fgDim)
        .animation(Theme.spring, value: line)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("freshness")
        // Chrome: whole words before large letters.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    struct Line: Equatable {
        var color: Color
        var message: String
        var tail: String?
        var beats: Bool
    }

    private var line: Line {
        if app.isDemo {
            let streaming = site.session.phase == .streaming
            return Line(color: streaming ? Theme.accentFill : Theme.fgMuted, message: L(streaming ? "Live demo · simulated home" : "Starting the demo"), tail: nil, beats: streaming)
        }
        let band = site.freshness(noCarrier: app.connectHelp != nil)
        let tail = [band.wait, band.age.flatMap { $0 == "—" ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
        return Line(color: FreshnessTone.color(band.tone), message: band.message, tail: tail.isEmpty ? nil : "· \(tail)", beats: band.tone == .live)
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

/// Freshness's colours, one per tone.
enum FreshnessTone {
    static func color(_ tone: Freshness.Tone) -> Color {
        switch tone {
        case .live: return Theme.freshLive
        case .stale: return Theme.freshStale
        case .reaching, .lost: return Theme.freshLost
        case .busy: return Theme.freshStale
        }
    }
}

/// Holds a part of a fixed page at `cap` while the page has to fit the
/// screen, and lets it grow freely at the accessibility sizes, where the
/// page scrolls instead.
struct FitCap: ViewModifier {
    let cap: DynamicTypeSize
    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        if size.isAccessibilitySize {
            content
        } else {
            content.dynamicTypeSize(...cap)
        }
    }
}

extension View {
    func fitCap(_ cap: DynamicTypeSize) -> some View { modifier(FitCap(cap: cap)) }
}
