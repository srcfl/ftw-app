import Foundation
import FTWShared

/// The tunnel first, the relay when FTW Cloud cannot carry the box session.
///
/// For one release, while boxes, FTW Cloud and phones move to the tunnel. The
/// tunnel has to prove itself: until a frame from the box has come through
/// it, a refusal, an unreachable service or a session ended before any
/// answer moves this carrier to the relay, and so does `tunnelWaitMs`
/// without one. A tunnel that carried and then dropped gets the same window
/// to carry again. Once on the relay it stays there; the next carrier, built
/// when the app comes back to the front, tries the tunnel again.
///
/// `kind` says which one carries, so the freshness band names the path the
/// readings really took.
@MainActor
public final class FallbackCarrier: Carrier {
    /// Long enough for TLS, the app session and the box's answer on a slow
    /// mobile link; short enough that a missing tunnel costs one glance.
    static let tunnelWaitMs: Double = 5_000

    public private(set) var status: CarrierStatus
    public var kind: CarrierKind { active.kind }
    /// Whether the relay took over.
    public private(set) var onRelay = false

    private var active: Carrier
    private let makeRelay: (@MainActor () -> Carrier)?
    private let scheduler: Scheduler
    /// A frame from the box has come through the tunnel since it last
    /// opened.
    private var carrying = false
    private var wait: Cancellable?
    private var closed = false

    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }

    /// `relay` builds the relay carrier when it is needed, and not before:
    /// a socket held open in reserve would take one of the relay's streams
    /// for the home. Nil leaves the tunnel to manage alone.
    public init(tunnel: TunnelCarrier, relay: (@MainActor () -> Carrier)?, scheduler: Scheduler) {
        active = tunnel
        makeRelay = relay
        self.scheduler = scheduler
        status = tunnel.status
        tunnel.setHandlers(
            onFrame: { [weak self] bytes in self?.tunnelFrame(bytes) },
            onStatus: { [weak self] s in self?.tunnelStatus(s) }
        )
        if case .closed = tunnel.status {
            toRelay()
        } else {
            startWait()
        }
    }

    public func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    @discardableResult
    public func send(_ frame: Bytes) -> Bool { active.send(frame) }

    public func beginSession() { active.beginSession() }

    public func wake() { active.wake() }

    public func close(reason: String = "closed by client") {
        guard !closed else { return }
        closed = true
        wait?.cancel()
        active.close(reason: reason)
        status = .closed(reason: reason, retryable: false)
        onFrame = { _ in }
        onStatus = { _ in }
    }

    // MARK: Inside

    private func tunnelFrame(_ bytes: Bytes) {
        if !carrying {
            carrying = true
            wait?.cancel()
            wait = nil
        }
        onFrame(bytes)
    }

    private func tunnelStatus(_ s: CarrierStatus) {
        guard !closed, !onRelay else { return }
        if case .closed(_, let retryable) = s {
            if !retryable || !carrying {
                toRelay()
                return
            }
            carrying = false
            startWait()
        }
        setStatus(s)
    }

    private func startWait() {
        wait?.cancel()
        wait = scheduler.after(Self.tunnelWaitMs) { [weak self] in
            guard let self, !self.carrying else { return }
            self.toRelay()
        }
    }

    private func toRelay() {
        guard !closed, !onRelay, let makeRelay else {
            if !closed, makeRelay == nil { setStatus(active.status) }
            return
        }
        onRelay = true
        wait?.cancel()
        wait = nil
        let tunnel = active
        tunnel.setHandlers(onFrame: { _ in }, onStatus: { _ in })
        tunnel.close(reason: "the relay took over")
        let relay = makeRelay()
        active = relay
        relay.setHandlers(
            onFrame: { [weak self] bytes in self?.onFrame(bytes) },
            onStatus: { [weak self] s in self?.setStatus(s) }
        )
        // Whatever the tunnel began is gone; the session starts again on the
        // relay once it opens.
        setStatus(.closed(reason: "moving to the relay", retryable: true))
        setStatus(relay.status)
    }

    private func setStatus(_ next: CarrierStatus) {
        guard !closed, next != status else { return }
        status = next
        onStatus(next)
    }
}
