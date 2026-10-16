import Foundation
import FTWShared
import Observation

/// Every model one home's screens read, built once per home and kept while
/// tabs switch, so a second visit is instant and keeps its state.
@MainActor
public final class HomeModels {
    public let site: SiteModel
    public let prices: PriceModel
    public let status: StatusWatch
    public let charging: ChargingWatch
    public let savings: SavingsModel
    public let loadpoints: LoadpointsModel
    /// Live, history, plan and mode for Now's nodes.
    public let nodes: NodeModels
    /// Today over the grid, for the grid widget.
    public let gridToday: GridTodayShare

    /// `cache` is what the app left for its widgets. Each model opens on
    /// the sealed home file first, and on these records where it has none.
    init(site: SiteModel, cache: CacheReader?) {
        self.site = site
        prices = PriceModel(site: site, cache: cache)
        status = StatusWatch(site: site)
        charging = ChargingWatch(site: site)
        savings = SavingsModel(site: site)
        loadpoints = LoadpointsModel(site: site, charging: charging, cache: cache)
        nodes = NodeModels(site: site, loadpoints: loadpoints, prices: prices, cache: cache)
        gridToday = GridTodayShare(site: site, history: nodes.history, prices: prices)
        // The nodes Now drew, so the next launch draws them in their places
        // before its first reading.
        site.keep { [weak site, weak loadpoints] home in
            guard let site, let loadpoints else { return }
            home.nodes = site.lastFrameAtMs == nil ? site.kept?.nodes : NowFlow.nodes(fields: site.session.fields, hasCar: !loadpoints.points.isEmpty)
        }
    }
}

/// Builds the carrier to a simulated home. FTWDemo supplies it; FTWKit holds
/// no fake box of its own.
public typealias DemoCarrier = @MainActor (Scheduler) -> Carrier

/// No carrier could be built from what this phone holds. Every other
/// failure heals itself because the carrier reconnects from inside; these
/// are the ones with nothing to reconnect, so the screen offers a way back.
public struct ConnectError: Error, Equatable, HelpfulError {
    public enum Kind: Sendable { case notPaired, notEnrolled, locked, stalePairing }
    public let kind: Kind
    public let help: String
}

/// The shell: which home is open, how it is reached, pairing, the demo and
/// leaving. Paints before any data arrives and never blocks on the network.
@Observable
@MainActor
public final class AppModel {
    public private(set) var home: HomeModels?
    /// What to do when no carrier could be built. Nil while one exists.
    public private(set) var connectHelp: String?
    /// The pairing screen, opened from a home that has lost its way in.
    public var recovering = false
    /// The last sign-out could not clear the disk; the home was put back.
    public private(set) var leaveFailed = false
    /// A pairing link that arrived from outside, shown before it is trusted.
    public var offeredLink: String?
    public private(set) var isDemo = false
    /// The demo leaves its records for the widgets under the home "demo".
    /// Only a Debug build sets it, to photograph the widgets; the demo
    /// otherwise writes nothing.
    public var demoSharesWidgets = false
    /// The demo keeps its sealed cache like a paired home, so a cold start
    /// can be recorded and timed. Only a Debug build sets it.
    public var demoKeepsCache = false

    @ObservationIgnored public let vault: Vault
    @ObservationIgnored public let sites: SiteList
    @ObservationIgnored public let pairing: Pairing
    @ObservationIgnored public let passkeys: PasskeyAuthenticator?
    @ObservationIgnored let store: SecureStore
    @ObservationIgnored let files: SealedFiles?
    @ObservationIgnored let shared: AppGroupFiles?
    @ObservationIgnored let sharedWritten: (@MainActor () -> Void)?
    @ObservationIgnored let demo: DemoCarrier?
    @ObservationIgnored let scheduler: Scheduler
    @ObservationIgnored let build: String
    @ObservationIgnored let ua: String
    @ObservationIgnored let relayURL: URL
    @ObservationIgnored let cloudEndpoint: CloudEndpoint?
    @ObservationIgnored let makeSocket: WebSocketFactory
    /// FTW Cloud's socket: the app races QUIC against the WebSocket
    /// (`CloudSockets.racing`). Tests leave it nil and get `makeSocket`.
    @ObservationIgnored let makeCloudSocket: WebSocketFactory
    @ObservationIgnored private var connectGeneration = 0
    /// `suspend` closed the session; the next look builds a new one.
    @ObservationIgnored private var suspended = false

    public init(
        store: SecureStore,
        files: SealedFiles?,
        shared: AppGroupFiles? = nil,
        sharedWritten: (@MainActor () -> Void)? = nil,
        passkeys: PasskeyAuthenticator?,
        scheduler: Scheduler = LiveScheduler.shared,
        build: String,
        ua: String,
        relayURL: URL = Origin.relayURL,
        cloudEndpoint: CloudEndpoint? = CloudEndpoint.current,
        makeSocket: @escaping WebSocketFactory = URLSessionWebSocket.factory(),
        makeCloudSocket: WebSocketFactory? = nil,
        demo: DemoCarrier? = nil
    ) {
        self.store = store
        self.files = files
        self.shared = shared
        self.sharedWritten = sharedWritten
        self.demo = demo
        self.passkeys = passkeys
        self.scheduler = scheduler
        self.build = build
        self.ua = ua
        self.relayURL = relayURL
        self.cloudEndpoint = cloudEndpoint
        self.makeSocket = makeSocket
        self.makeCloudSocket = makeCloudSocket ?? makeSocket
        vault = Vault(store: store)
        sites = SiteList(store: store)
        pairing = Pairing(vault: vault, sites: sites, passkeys: passkeys, now: { [scheduler] in scheduler.nowMs })
    }

    public var site: SiteModel? { home?.site }

    /// Nothing paired and nothing to show: the only screen is pairing.
    public var needsPairing: Bool { home == nil || recovering || offeredLink != nil }

    /// The launch path: a paired phone paints its cached home at once and
    /// connects behind it.
    public func launch() {
        guard home == nil, let current = sites.current() else { return }
        open(current.siteId)
    }

    /// Point the app at a home and connect to it.
    public func open(_ siteId: String) {
        exitDemo()
        home?.site.destroy()
        let site = SiteModel(siteId: siteId, build: build, ua: ua, scheduler: scheduler, files: files, shared: shared)
        site.stepUp = { [weak self] in await self?.stepUp() ?? .unavailable }
        site.sharedWritten = sharedWritten
        site.learnedHome = { [weak self] home in
            self?.sites.update(siteId) { $0.cloudHome = home }
        }
        home = HomeModels(site: site, cache: shared.map { CacheReader(sources: [$0]) })
        sites.setCurrent(siteId)
        site.start()
        recovering = false
        suspended = false
        Task { await connect() }
    }

    func stepUp() async -> StepUpOutcome {
        await vault.stepUp(passkeys)
    }

    /// Build the carrier stack silently. Reading your own house is not a
    /// privilege; a device enrolled before the local copy pays one last
    /// prompt, and never again.
    public func connect() async {
        guard let site = home?.site, let siteId = site.siteId else { return }
        connectGeneration += 1
        let mine = connectGeneration
        do {
            guard let stored = sites.get(siteId) else {
                throw ConnectError(kind: .notPaired, help: AppWords.text("This phone has no record of that home."))
            }
            guard vault.isEnrolled else {
                throw ConnectError(kind: .notEnrolled, help: AppWords.text("This device has no key for that home."))
            }
            // The rendezvous secret is read from the QR, never derived: a
            // handle derived from the box key would be one household
            // identifier good for years. A home id reaches the box through
            // FTW Cloud instead.
            let secret = stored.rendezvousSecret?.byteArray
            guard secret != nil || stored.cloudHome != nil else {
                throw ConnectError(kind: .stalePairing, help: AppWords.text("This home was paired before this app could reach it privately."))
            }
            var wrapping = try vault.silentWrappingKey()
            if wrapping == nil {
                let prompted = try await vault.unlockWrappingKey(passkeys)
                try vault.ensureLocalCopy(prompted)
                wrapping = prompted
            }
            let device = try vault.deviceKey(wrapping!)
            guard mine == connectGeneration, home?.site === site else { return }

            let box = stored.boxStaticKey.byteArray
            let code = stored.pairingCode?.byteArray
            // FTW Cloud first: the box session rides it when the box takes
            // the tunnel.
            site.connectCloud(deviceKey: device, makeSocket: makeCloudSocket, endpoint: cloudEndpoint, home: stored.cloudHome, pairingCode: code)
            var relay: (@MainActor () -> Carrier)?
            if let secret {
                relay = { [relayURL, scheduler, makeSocket] in
                    RelayCarrier(url: relayURL, secret: secret, scheduler: scheduler, makeSocket: makeSocket)
                }
            }
            let inner: Carrier
            if let cloud = site.tunnelCloud() {
                inner = FallbackCarrier(tunnel: TunnelCarrier(cloud: cloud, scheduler: scheduler), relay: relay, scheduler: scheduler)
            } else if let relay {
                inner = relay()
            } else {
                throw ConnectError(kind: .stalePairing, help: AppWords.text("This home was paired before this app could reach it privately."))
            }
            let noise = NoiseCarrier(
                inner: inner,
                staticKey: device,
                remoteStatic: box,
                prologue: NoiseCarrier.prologue(boxStaticKey: box),
                handshakePayload: code ?? [],
                scheduler: scheduler
            )
            if site.connect(noise) { connectHelp = nil }
        } catch is PasskeyCancelled {
            // A closed sheet is not a lost key: say what happened and let
            // the person try again.
            guard mine == connectGeneration else { return }
            connectHelp = AppWords.text("Unlocking was cancelled. Try again to open your home.")
        } catch let e as HelpfulError {
            guard mine == connectGeneration else { return }
            connectHelp = e.help
        } catch {
            guard mine == connectGeneration else { return }
            connectHelp = AppWords.text(Vault.lockedHelp)
        }
    }

    /// Pull to refresh: a fresh stream in place, or a new carrier if there
    /// was none.
    public func refresh() async {
        if isDemo {
            site?.refresh()
            return
        }
        if connectHelp != nil || site?.core.hasCarrier == false {
            await connect()
        } else {
            site?.refresh()
        }
    }

    /// Whether anyone is looking. Coming back from the background builds a
    /// new carrier, because `suspend` closed the old one.
    public func setVisible(_ visible: Bool) {
        guard let site else { return }
        site.setVisible(visible)
        if visible, suspended {
            suspended = false
            Task { await connect() }
        }
    }

    /// Inactive: a glance at Control Center or the app switcher, or the app
    /// on its way back to the front. The stream keeps its rate, a return
    /// from the background dials at once, so the handshake runs beside the
    /// app switch, and what is on screen is written in case the app is
    /// closed from the switcher.
    public func glance() {
        setVisible(true)
        site?.persistNow()
    }

    /// The app went to the background: close the session and keep what is
    /// on screen. The demo has no socket to free and keeps running. While an
    /// Apple Watch looks through this phone nothing closes; the look's end
    /// calls this again.
    public func suspend() {
        // A watch looking keeps the session; the end of its look suspends.
        guard let site, !site.watched else { return }
        if isDemo {
            site.setVisible(false)
        } else {
            site.suspend()
            suspended = true
        }
    }

    public func networkOnline() {
        site?.networkOnline()
    }

    /// A pairing link arrived. It is an offer, never an instruction: anyone
    /// can send a link, so it is shown with the box it names first. A link
    /// to the box this phone already has is a leftover and is dropped.
    public func offer(_ link: String) {
        guard let enrollment = try? Enrollment.parse(scanned: link) else {
            offeredLink = link
            return
        }
        if let current = site?.siteId, SiteList.siteID(enrollment.boxStaticPublic) == current, sites.get(current) != nil {
            return
        }
        offeredLink = link
    }

    public func paired(_ siteId: String) {
        offeredLink = nil
        recovering = false
        open(siteId)
    }

    // MARK: The demo

    /// Whether this build carries the simulated home.
    public var canDemo: Bool { demo != nil }

    /// A simulated home in this process. Nothing is written and no passkey
    /// is asked for; leaving it touches no saved home.
    public func startDemo() {
        guard let demo else { return }
        home?.site.destroy()
        let shares = demoSharesWidgets && shared != nil
        let keeps = demoKeepsCache && files != nil
        let site = SiteModel(siteId: shares || keeps ? "demo" : nil, build: build, ua: ua, scheduler: scheduler, files: keeps ? files : nil, shared: shares ? shared : nil, isDemo: true, demoShares: shares)
        if shares { site.sharedWritten = sharedWritten }
        site.ceilingW = 11_000
        home = HomeModels(site: site, cache: shares ? shared.map { CacheReader(sources: [$0]) } : nil)
        isDemo = true
        recovering = false
        offeredLink = nil
        connectHelp = nil
        site.start()
        site.connect(demo(scheduler))
    }

    public func exitDemo() {
        guard isDemo else { return }
        // The demo's Live Activity must not outlive it: its button would
        // reach the home that opens next.
        home?.loadpoints.endLiveActivities()
        home?.site.destroy()
        home = nil
        isDemo = false
        if let current = sites.current() { open(current.siteId) }
    }

    // MARK: Leaving

    /// Sign out on this phone: the stream stops first and the disk is
    /// cleared second, so a reading landing mid-clear cannot write the home
    /// back. The widgets lose their records too.
    public func leave() {
        home?.loadpoints.endLiveActivities()
        home?.site.destroy()
        home = nil
        vault.reset()
        sites.clear()
        files?.clear()
        shared?.removeAll()
        sharedWritten?()
        connectHelp = nil
        leaveFailed = false
        recovering = false
    }
}
