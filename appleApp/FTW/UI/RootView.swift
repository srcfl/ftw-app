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
                // A new home is a new set of tabs: no route, tab or model
                // count carries over from the last one.
                HomeView(app: app, home: home)
                    .id(ObjectIdentifier(home))
            }
        }
        .background(Theme.surface.ignoresSafeArea())
        .tint(Theme.accent)
        .onAppear { LaunchClock.mark("first frame") }
        .cloudConsent(app)
        #if DEBUG
        .overlay(alignment: .topLeading) { if FrameGapProbe.enabled { FrameGapProbe() } }
        #endif
    }
}

/// Where a home can go inside a tab: each node's own view, its day, the
/// car, the plan and its price, the savings, and an assistant's offer.
enum HomeRoute: Hashable {
    /// One charger's car; nil is the first.
    case car(String?)
    /// Live, history, plan and mode for one node of the flow.
    case node(EnergyNode)
    /// One node's view open on today, from History.
    case day(EnergyNode)
    /// The plan ahead, from Now's plan card.
    case plan
    /// The price ahead, from the plan.
    case price
    /// What the home saved, from History and the home's node.
    case savings
    /// An assistant's consent link: its offer, to Face ID.
    case offer(OfferLink)

    /// The name in the bar, the same as the screen's own title.
    var title: String {
        switch self {
        case .car: return L("Car")
        case .node(let node), .day(let node): return node.title
        case .plan: return PlanGlance.title
        case .price: return L("Electricity price")
        case .savings: return L("Savings")
        case .offer: return AccessWords.text("Add an assistant")
        }
    }

    /// Where a home opens: Now, at its root. Debug builds take `-FTWTab
    /// car`, `-FTWNode battery`, `-FTWTab history` and the like, so every
    /// screen of the demo can be photographed.
    static var initial: (tab: HomeTab, path: [HomeRoute]) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let node = defaults.string(forKey: "FTWNode").flatMap(EnergyNode.init(rawValue:)) { return (.now, [.node(node)]) }
        switch defaults.string(forKey: "FTWTab") {
        case "car": return (.now, [.car(nil)])
        case "plan": return (.plan, [])
        case "price": return (.plan, [.price])
        case "history": return (.history, [])
        case "savings": return (.history, [.savings])
        case "home": return (.home, [])
        default: break
        }
        // The settings live on Home now; the old knob opens it.
        if defaults.string(forKey: "FTWSheet") == "settings" { return (.home, []) }
        #endif
        return (.now, [])
    }
}

/// One home in four tabs: Now, the plan, History and Home. Each keeps its
/// own stack, so a node opened on Now is still open after a look at the
/// plan, and a second tap on a tab takes it back to its top. Every model
/// is the home's, built once, so a tab paints at once.
struct HomeView: View {
    let app: AppModel
    let home: HomeModels
    @State private var tab: HomeTab
    @State private var paths: [HomeTab: [HomeRoute]]
    @State private var sheet: HomeSheet?

    init(app: AppModel, home: HomeModels) {
        self.app = app
        self.home = home
        let start = HomeRoute.initial
        _tab = State(initialValue: start.tab)
        _paths = State(initialValue: [start.tab: start.path])
    }

    var body: some View {
        TabView(selection: selection) {
            Tab(HomeTab.now.title, systemImage: HomeTab.now.symbol, value: HomeTab.now) {
                TabStack(app: app, home: home, path: path(.now)) { zoom in
                    NowView(app: app, home: home, zoom: zoom)
                        .homeBar(app: app, home: home, title: app.homeName, id: "now.title")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                ModeMenu(mode: home.nodes.mode) { sheet = .mode }
                            }
                        }
                }
            }
            Tab(HomeTab.plan.title, systemImage: HomeTab.plan.symbol, value: HomeTab.plan) {
                TabStack(app: app, home: home, path: path(.plan)) { _ in
                    PlanView(app: app, home: home)
                        .homeBar(app: app, home: home, title: PlanGlance.title)
                }
            }
            Tab(HomeTab.history.title, systemImage: HomeTab.history.symbol, value: HomeTab.history) {
                TabStack(app: app, home: home, path: path(.history)) { zoom in
                    HistoryTabView(home: home, zoom: zoom)
                        .homeBar(app: app, home: home, title: HomeTab.history.title)
                }
            }
            Tab(HomeTab.home.title, systemImage: HomeTab.home.symbol, value: HomeTab.home) {
                TabStack(app: app, home: home, path: path(.home)) { _ in
                    HomeTabView(app: app, home: home, sheet: $sheet) { paths[.home] = [] }
                        .homeBar(app: app, home: home, title: HomeTab.home.title)
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .mode: ModeSheet(mode: home.nodes.mode, plan: home.nodes.planShare)
            case .about(let start): AboutView(app: app, start: start)
            }
        }
        // A consent page's link opens its offer on Home, over anything
        // open, once this phone can grant from here. The newest link wins:
        // an offer page already open goes.
        .onChange(of: app.accessLink, initial: true) { _, link in
            guard let link, home.access != nil else { return }
            app.accessLink = nil
            sheet = nil
            var stack = paths[.home] ?? []
            stack.removeAll { if case .offer = $0 { return true } else { return false } }
            stack.append(.offer(link))
            paths[.home] = stack
            tab = .home
        }
        // Now and the car read the chargers from one model, so a screen
        // appearing asks the box once; the cars after each hello.
        .onAppear {
            home.loadpoints.activate()
            home.cars.activate()
        }
        .onDisappear {
            home.loadpoints.deactivate()
            home.cars.deactivate()
        }
        #if DEBUG
        // For screenshots: `-FTWAbout about`, `remove` or a file name such
        // as `LICENSE` opens Source & licenses.
        .task {
            if let start = UserDefaults.standard.string(forKey: "FTWAbout").flatMap(AboutView.Start.init) { sheet = .about(start) }
        }
        #endif
    }

    /// A second tap on the open tab takes it back to its top.
    private var selection: Binding<HomeTab> {
        Binding(get: { tab }, set: { chosen in
            if chosen == tab { paths[chosen] = [] }
            tab = chosen
        })
    }

    private func path(_ t: HomeTab) -> Binding<[HomeRoute]> {
        Binding(get: { paths[t] ?? [] }, set: { paths[t] = $0 })
    }
}

/// One tab's stack: its root, and every route a home's screens open. Each
/// route zooms out of the view that names it as its source: a node on Now,
/// a day in History, the car row in the car's node view.
private struct TabStack<Root: View>: View {
    let app: AppModel
    let home: HomeModels
    @Binding var path: [HomeRoute]
    @ViewBuilder let root: (Namespace.ID) -> Root
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            root(zoom)
                .background(Theme.surface)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: HomeRoute.self) { route in
                    destination(route)
                        .homeBar(app: app, home: home, title: route.title)
                        .navigationTransition(.zoom(sourceID: route, in: zoom))
                }
        }
    }

    @ViewBuilder private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .car(let id):
            CarView(app: app, home: home, id: id)
        case .node(let node):
            NodeView(app: app, home: home, node: node, zoom: zoom)
        case .day(let node):
            NodeView(app: app, home: home, node: node, zoom: zoom, opening: .today)
        case .plan:
            PlanView(app: app, home: home)
        case .price:
            PriceView(home: home)
        case .savings:
            SavingsView(home: home)
        case .offer(let link):
            // Its own identity, so a newer link in the same place gets a
            // new flow, not the old one's state.
            OfferFlowView(app: app, flow: OfferFlow(link: link, lookup: app.offerLookup, keys: app.offerKeys))
                .id(link)
        }
    }
}

/// What opens over a home: the mode sheet, from Now's mode button and
/// Home, and Source & licenses.
enum HomeSheet: Hashable, Identifiable {
    case mode
    case about(AboutView.Start)
    var id: Self { self }
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
