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

    private let vault = Vault(store: MemoryStore())
    private let sites = SiteStore(kv: MemoryStore())
    private lazy var client: FtwClient = FtwClient(
        vault: vault,
        sites: sites,
        sockets: IosSockets(),
        passkeys: LocalPasskey(),
        relayUrl: OriginKt.RELAY_URL,
        build: "ios"
    )
    private var session: Session?

    func pair() {
        help = nil
        do {
            let scanned = paste
            site = try client.pair(scanned: scanned)
            connect()
        } catch let err as EnrollmentError {
            help = err.help
        } catch {
            help = "That code did not read cleanly. Hold the phone steady and scan it again."
        }
    }

    func applyScanned(_ raw: String) {
        paste = raw
        pair()
    }

    func connect() {
        guard let site else { return }
        do {
            let session = try client.connect(site: site)
            self.session = session
            session.subscribe { [weak self] snap in
                DispatchQueue.main.async {
                    self?.headline = snap.headline
                    self?.carrier = String(describing: snap.carrier)
                    self?.srcState = String(describing: snap.srcState)
                }
            }
        } catch let err as ConnectError {
            help = err.help
        } catch {
            help = "Could not reach your box."
        }
    }

    func forget() {
        session?.close()
        session = nil
        site = nil
        help = nil
    }
}
