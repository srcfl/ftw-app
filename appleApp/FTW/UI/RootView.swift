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
        .cloudConsent(app)
        #if DEBUG
        .overlay(alignment: .topLeading) { if FrameGapProbe.enabled { FrameGapProbe() } }
        #endif
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
    /// The price ahead, from the plan.
    case price
    /// What the home saved, from the home's node and the title's menu.
    case savings

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
        case "price": return [.plan, .price]
        case "savings": return [.savings]
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
    @State private var sheet: HomeSheet?
    /// A node on Now grows into its own view, and the car into the car view.
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            NowView(app: app, home: home, zoom: zoom)
                .background(Theme.surface)
                // The home's name, with the way to every other place behind
                // it: no button of its own on Now.
                .navigationTitle(app.homeName)
                .navigationBarTitleDisplayMode(.inline)
                .statusLine(app: app, home: home)
                .toolbar {
                    // The title's menu is drawn here rather than with
                    // `toolbarTitleMenu`, whose target also covers the
                    // status line under it: the name opens the menu, the
                    // line opens the control sheet.
                    ToolbarItem(placement: .title) {
                        TitleMenu(app: app, sheet: $sheet) { route in
                            if path.last != route { path.append(route) }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ModeMenu(mode: home.nodes.mode) { sheet = .mode }
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
                        case .price:
                            PriceView(home: home)
                        case .savings:
                            SavingsView(home: home)
                        }
                    }
                    .statusLine(app: app, home: home)
                    .navigationTransition(.zoom(sourceID: route, in: zoom))
                }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .settings: ModeSheet(mode: home.nodes.mode, app: app, plan: home.nodes.planShare)
            case .mode: ModeSheet(mode: home.nodes.mode, plan: home.nodes.planShare)
            case .about(let start): AboutView(app: app, start: start)
            }
        }
        // Now and the car read the chargers from one model, so a screen
        // appearing asks the box once.
        .onAppear { home.loadpoints.activate() }
        .onDisappear { home.loadpoints.deactivate() }
        #if DEBUG
        // For screenshots: `-FTWSheet settings` opens the settings, and
        // `-FTWAbout about`, `remove` or a file name such as `LICENSE` opens
        // Source & licenses there.
        .task {
            if UserDefaults.standard.string(forKey: "FTWSheet") == "settings" { sheet = .settings }
            if let start = UserDefaults.standard.string(forKey: "FTWAbout").flatMap(AboutView.Start.init) { sheet = .about(start) }
        }
        #endif
    }
}

/// What the title's menu and the mode button open over Now.
enum HomeSheet: Hashable, Identifiable {
    case settings
    case mode
    case about(AboutView.Start)
    var id: Self { self }
}

/// The home's name as the title, and its menu.
struct TitleMenu: View {
    let app: AppModel
    @Binding var sheet: HomeSheet?
    let open: (HomeRoute) -> Void

    var body: some View {
        Menu {
            HomeMenu(app: app, sheet: $sheet, open: open)
        } label: {
            HStack(spacing: 6) {
                Text(app.homeName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.ink2)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(app.homeName)
        .accessibilityHint(L("Homes, settings and about."))
        .accessibilityIdentifier("now.title")
        // Chrome in the bar: whole words before large letters.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The title's menu: what the home saved, the homes on this phone, how
/// this one is run, what the app is and how it treats your data, the way
/// out of the demo, and the build, in that order.
struct HomeMenu: View {
    let app: AppModel
    @Binding var sheet: HomeSheet?
    let open: (HomeRoute) -> Void

    var body: some View {
        Section {
            Button { open(.savings) } label: {
                Label(L("Savings"), systemImage: "banknote")
            }
            .accessibilityIdentifier("menu.savings")
        }
        Section {
            Menu {
                ForEach(app.homes) { h in
                    Button { app.open(h.siteId) } label: {
                        if !app.isDemo, app.site?.siteId == h.siteId {
                            Label(HomeName.title(h.label), systemImage: "checkmark")
                        } else {
                            Text(HomeName.title(h.label))
                        }
                    }
                }
                Button { app.recovering = true } label: {
                    Label(L("Pair a home"), systemImage: "qrcode.viewfinder")
                }
            } label: {
                Label(L("Homes"), systemImage: "house")
            }
            Button { sheet = .settings } label: {
                Label(L("Settings"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("menu.settings")
            Button { sheet = .about(.about) } label: {
                Label(L("About FTW"), systemImage: "info.circle")
            }
            .accessibilityIdentifier("menu.about")
            Link(destination: Origin.privacyURL()) {
                Label(AboutWords.text("Privacy"), systemImage: "hand.raised")
            }
        }
        if app.isDemo {
            Section {
                Button { app.exitDemo() } label: {
                    Label(L("Exit demo"), systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("demo.exit")
            }
        }
        Section {
            Text(verbatim: "FTW \(BuildSource.bundled.versionText)")
        }
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
