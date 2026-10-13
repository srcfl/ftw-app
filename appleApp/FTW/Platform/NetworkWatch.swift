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

    fileprivate func set(_ online: Bool) {
        if self.online != online { self.online = online }
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
            Task { @MainActor in self.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "energy.ftw.network"))
    }

    private func update(_ online: Bool) {
        NetworkState.shared.set(online)
        if online, !wasOnline { onOnline() }
        wasOnline = online
    }
}
