import Foundation
import Observation

/// Every model one home's screens read, built once per home and kept while
/// tabs switch, so a second visit is instant and keeps its state.
@MainActor
public final class HomeModels {
    public let site: SiteModel
    public let plan: PlanModel
    public let prices: PriceModel
    public let status: StatusWatch
    public let charging: ChargingWatch
    public let savings: SavingsModel
    public let energy: EnergyModel
    public let history: HistoryModel
    public let loadpoints: LoadpointsModel
    public let access: AccessModel
    public let notify: NotifyModel
    public let restart: RestartModel

    init(site: SiteModel, files: SealedFiles?, thisPhone: String?) {
        self.site = site
        plan = PlanModel(site: site)
        prices = PriceModel(site: site)
        status = StatusWatch(site: site)
        charging = ChargingWatch(site: site)
        savings = SavingsModel(site: site)
        energy = EnergyModel(site: site)
        history = HistoryModel(site: site, tiles: TileCache(files: site.isDemo ? nil : files, siteId: site.siteId ?? "demo"))
        loadpoints = LoadpointsModel(site: site, charging: charging)
        access = AccessModel(site: site, thisPhone: thisPhone)
        notify = NotifyModel(site: site)
        restart = RestartModel(site: site)
    }
}

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
    /// The Box screen's spare-key switch for the open home. Nil in the demo.
    public private(set) var sealedCopy: SealedCopyModel?

    @ObservationIgnored public let vault: Vault
    @ObservationIgnored public let sites: SiteList
    @ObservationIgnored public let escrow: Escrow
    @ObservationIgnored public let pairing: Pairing
    @ObservationIgnored public let passkeys: PasskeyAuthenticator?
    @ObservationIgnored let store: SecureStore
    @ObservationIgnored let files: SealedFiles?
    @ObservationIgnored let scheduler: Scheduler
    @ObservationIgnored let build: String
    @ObservationIgnored let ua: String
    @ObservationIgnored let relayURL: URL
    @ObservationIgnored let makeSocket: WebSocketFactory
    @ObservationIgnored private var demoBox: SimulatedBox?
    @ObservationIgnored private var connectGeneration = 0

    public init(
        store: SecureStore,
        files: SealedFiles?,
        passkeys: PasskeyAuthenticator?,
        scheduler: Scheduler = LiveScheduler.shared,
        build: String,
        ua: String,
        relayURL: URL = Origin.relayURL,
        escrowTransport: Escrow.Transport? = nil,
        makeSocket: @escaping WebSocketFactory = URLSessionWebSocket.factory()
    ) {
        self.store = store
        self.files = files
        self.passkeys = passkeys
        self.scheduler = scheduler
        self.build = build
        self.ua = ua
        self.relayURL = relayURL
        self.makeSocket = makeSocket
        vault = Vault(store: store)
        sites = SiteList(store: store)
        escrow = Escrow(vault: vault, sites: sites, transport: escrowTransport)
        pairing = Pairing(vault: vault, sites: sites, escrow: escrow, passkeys: passkeys, now: { [scheduler] in scheduler.nowMs })
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
        let site = SiteModel(siteId: siteId, build: build, ua: ua, scheduler: scheduler, files: files)
        site.stepUp = { [weak self] in await self?.stepUp() ?? .unavailable }
        home = HomeModels(site: site, files: files, thisPhone: vault.deviceIDOnBox)
        sealedCopy = SealedCopyModel(app: self, siteId: siteId)
        sites.setCurrent(siteId)
        site.start()
        recovering = false
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
                throw ConnectError(kind: .notPaired, help: "This phone has no record of that home.")
            }
            guard vault.isEnrolled else {
                throw ConnectError(kind: .notEnrolled, help: "This device has no key for that home.")
            }
            // Read from the QR, never derived: a handle derived from the box
            // key would be one household identifier good for years.
            guard let secret = stored.rendezvousSecret?.byteArray else {
                throw ConnectError(kind: .stalePairing, help: "This home was paired before this app could reach it privately.")
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
            let relay = RelayCarrier(url: relayURL, secret: secret, scheduler: scheduler, makeSocket: makeSocket)
            let noise = NoiseCarrier(
                inner: relay,
                staticKey: device,
                remoteStatic: box,
                prologue: NoiseCarrier.prologue(boxStaticKey: box),
                handshakePayload: stored.pairingCode?.byteArray ?? [],
                scheduler: scheduler
            )
            if site.connect(noise) { connectHelp = nil }
        } catch let e as HelpfulError {
            guard mine == connectGeneration else { return }
            connectHelp = e.help
        } catch {
            guard mine == connectGeneration else { return }
            connectHelp = "This device can no longer unlock its key. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR."
        }
    }

    /// Pull to refresh: a fresh stream in place, or a new carrier if there
    /// was none.
    public func refresh() async {
        if isDemo {
            demoBox?.tick()
            return
        }
        if connectHelp != nil || site?.core.hasCarrier == false {
            await connect()
        } else {
            site?.refresh()
        }
    }

    public func setVisible(_ visible: Bool) {
        site?.setVisible(visible)
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

    /// A simulated home in this process. Nothing is written and no passkey
    /// is asked for; leaving it touches no saved home.
    public func startDemo() {
        home?.site.destroy()
        let site = SiteModel(siteId: nil, build: build, ua: ua, scheduler: scheduler, files: nil, isDemo: true)
        site.ceilingW = 11_000
        let box = SimulatedBox(scheduler: scheduler)
        demoBox = box
        home = HomeModels(site: site, files: nil, thisPhone: "Qm94T3du")
        sealedCopy = nil
        isDemo = true
        recovering = false
        offeredLink = nil
        connectHelp = nil
        site.start()
        site.connect(LoopbackCarrier(box: box, scheduler: scheduler))
    }

    public func exitDemo() {
        guard isDemo else { return }
        home?.site.destroy()
        home = nil
        sealedCopy = nil
        demoBox = nil
        isDemo = false
        if let current = sites.current() { open(current.siteId) }
    }

    // MARK: Leaving

    /// Sign out on this phone: the stream stops first and the disk is
    /// cleared second, so a reading landing mid-clear cannot write the home
    /// back. The sealed copy at Sourceful stays; removing it is its own act.
    public func leave() {
        home?.site.destroy()
        home = nil
        sealedCopy = nil
        vault.reset()
        sites.clear()
        files?.clear()
        connectHelp = nil
        leaveFailed = false
        recovering = false
    }
}
