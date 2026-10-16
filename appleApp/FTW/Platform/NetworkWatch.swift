import Foundation
import Network
import Observation

/// Whether this phone has a network path at all, for the freshness line:
/// with none, the honest sentence is that the phone is offline, not that
/// the box cannot be reached.
@Observable
@MainActor
final class NetworkState {
    static let shared = NetworkState()
    private(set) var online = true
    /// The network the phone is on: its interfaces and gateways. FTW Cloud
    /// remembers per network whether QUIC or the WebSocket got through.
    @ObservationIgnored private(set) var name = ""

    fileprivate func set(_ online: Bool, name: String) {
        if self.online != online { self.online = online }
        self.name = name
    }
}

/// Tells the app when a network path comes back, so a stream replaces its
/// dead socket at once instead of waiting out a timeout. Lives as long as
/// the app does.
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private let onOnline: @MainActor () -> Void
    private var wasOnline = true

    init(onOnline: @escaping @MainActor () -> Void) {
        self.onOnline = onOnline
        // Sendable on purpose: the monitor calls this on its own queue, and a
        // closure left to infer main-actor isolation would trap there.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            let name = (path.availableInterfaces.map { "\($0.type)" } + path.gateways.map { "\($0)" }).joined(separator: ",")
            Task { @MainActor in self.update(online, name: name) }
        }
        monitor.start(queue: DispatchQueue(label: "energy.ftw.network"))
    }

    private func update(_ online: Bool, name: String) {
        NetworkState.shared.set(online, name: name)
        if online, !wasOnline { onOnline() }
        wasOnline = online
    }
}
