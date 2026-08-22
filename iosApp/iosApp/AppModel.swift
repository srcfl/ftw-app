import SwiftUI
import Shared

@MainActor
final class AppModel: ObservableObject {
    @Published var site: PairedSite?
    @Published var headline: String = "Waiting for the first reading."
    @Published var carrier: String = "none"
    @Published var srcState: String = "never"
    @Published var grid: String = "—"
    @Published var pv: String = "—"
    @Published var battery: String = "—"
    @Published var load: String = "—"
    @Published var help: String?
    @Published var paste: String = ""

    private let vault: Vault
    private let sites: SiteStore
    private let readings: ReadingsCache
    private lazy var client: FtwClient = FtwClient(
        vault: vault,
        sites: sites,
        sockets: IosSockets(),
        passkeys: IosPasskey(),
        relayUrl: OriginKt.RELAY_URL,
        build: "ios"
    )
    private var session: Session?
    private var epoch = 0

    init() {
        let kv = KeychainStore()
        vault = Vault(store: kv)
        sites = SiteStore(kv: kv)
        readings = ReadingsCache(kv: kv)
        if let paired = sites.all().first {
            site = paired
            if let cached = readings.get() {
                let nums = NowNumbersKt.nowNumbers(fields: cached.fields)
                headline = SessionKt.headlineOf(readings: cached)
                carrier = "cache"
                grid = nums.grid
                pv = nums.pv
                battery = nums.battery
                load = nums.load
            }
            connect()
        }
    }

    func pair() {
        help = nil
        let scanned = paste
        Task {
            do {
                let wrapping = try await IosPasskey.enroll()
                let paired = try client.pair(scanned: scanned, wrapping: wrapping)
                await MainActor.run {
                    self.site = paired
                    self.connect()
                }
            } catch let err as EnrollmentError {
                await MainActor.run { self.help = err.help }
            } catch let err as VaultError {
                await MainActor.run { self.help = err.help }
            } catch {
                await MainActor.run {
                    self.help = "That code did not read cleanly. Hold the phone steady and scan it again."
                }
            }
        }
    }

    func applyScanned(_ raw: String) {
        paste = raw
        pair()
    }

    func connect() {
        guard let site else { return }
        session?.close()
        epoch += 1
        let mine = epoch
        do {
            let session = try client.connect(site: site)
            self.session = session
            if let cached = readings.get() {
                session.restore(readings: cached)
            }
            session.subscribe { [weak self] snap in
                let hasFields = snap.readings.fields.count > 0
                let nums = NowNumbersKt.nowNumbers(fields: snap.readings.fields)
                DispatchQueue.main.async {
                    guard let self, self.epoch == mine else { return }
                    self.headline = snap.headline
                    self.carrier = String(describing: snap.carrier)
                    self.srcState = String(describing: snap.srcState)
                    if hasFields {
                        self.grid = nums.grid
                        self.pv = nums.pv
                        self.battery = nums.battery
                        self.load = nums.load
                        self.readings.put(readings: snap.readings)
                    }
                }
            }
        } catch let err as ConnectError {
            help = err.help
        } catch {
            help = "Could not reach your box."
        }
    }

    func wake() {
        session?.wake()
    }

    func forget() {
        epoch += 1
        session?.close()
        session = nil
        vault.clear()
        sites.clear()
        readings.clear()
        site = nil
        headline = "Waiting for the first reading."
        carrier = "none"
        srcState = "never"
        grid = "—"
        pv = "—"
        battery = "—"
        load = "—"
        help = nil
        paste = ""
    }
}
