import Foundation
import FTWShared

/// The phone's own session with its box, carried by FTW Cloud.
///
/// Each frame rides the app session to FTW Cloud as `tun {sid, d}`, and FTW
/// Cloud hands it to the box under the device its own handshake proved. `d`
/// is the box session byte for byte, Noise to the box's key, so FTW Cloud
/// can drop or delay a frame and can neither read nor forge one. Lane 0
/// keeps its padding inside it. The box sends each reading as it lands
/// rather than on a one-second pulse, and a beat when nothing moves for
/// the subscribed period.
///
/// One socket instead of two: the box session's message 1 waits for the app
/// session's message 1 and rides inside it, so the box session is up one
/// round trip after TLS.
///
/// srcfl/ftw `docs/protocol-cloud.md`, "Tunnel", is the normative text.
@MainActor
public final class TunnelCarrier: Carrier {
    static let backoffBaseMs: Double = 500
    static let backoffCapMs: Double = 60_000
    /// A session that carried this long before it ended starts the backoff
    /// over. A shorter one does not, so two sessions of one device cannot
    /// take the box's slot from each other in a loop.
    static let settledMs: Double = 30_000

    public let kind: CarrierKind = .tunnel
    public private(set) var status: CarrierStatus = .connecting

    private let cloud: CloudCarrier
    private let scheduler: Scheduler
    /// This session's number on the wire. A new one for every handshake.
    private(set) var sid: UInt32 = 0
    /// The session's message 1, while the app session cannot carry it yet.
    private var first: Bytes?
    /// The box or the service ended the session; a new one starts after
    /// this backoff.
    private var ended = false
    private var attempt = 0
    /// Frames from the box in this session: message 2, then transport.
    private var framesThisSession = 0
    /// When the box's first transport frame of this session arrived: the
    /// box claims the device's slot on the phone's first transport frame,
    /// so only its answer to that shows the session is this phone's.
    private var carryingSinceMs: Double?
    private var retry: Cancellable?
    private var shutdown = false

    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }

    /// `cloud` is the home's FTW Cloud session. It stays the site model's:
    /// closing this carrier ends the box session and leaves the app session
    /// up for the readable copy.
    public init(cloud: CloudCarrier, scheduler: Scheduler) {
        self.cloud = cloud
        self.scheduler = scheduler
        cloud.tunnel = self
        // A session waiting out a backoff dials now: someone wants the box.
        if case .closed(_, true) = cloud.status { cloud.wake() }
        status = follow(cloud.status)
    }

    public func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    public func beginSession() {
        sid = UInt32.random(in: 1...UInt32.max)
        first = nil
        framesThisSession = 0
        carryingSinceMs = nil
    }

    @discardableResult
    public func send(_ frame: Bytes) -> Bool {
        guard !shutdown, status.isOpen, frame.count <= CloudWire.tunDataMax else { return false }
        if cloud.status.isOpen {
            return cloud.sendTun(CloudWire.Tun(sid: sid, d: frame))
        }
        // Before the app session's message 2 only message 1 can wait, and
        // only one: it rides message 1, or goes the moment message 2 is in.
        // Nothing else of a session exists before its handshake answers.
        guard first == nil else { return false }
        first = frame
        return true
    }

    public func wake() {
        guard !shutdown else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        ended = false
        cloud.redial()
        setStatus(follow(cloud.status))
    }

    /// Ends the session at the box and leaves the app session to the site
    /// model.
    public func close(reason: String = "closed by client") {
        guard !shutdown else { return }
        shutdown = true
        retry?.cancel()
        if first == nil, sid != 0, cloud.status.isOpen { cloud.sendTun(CloudWire.Tun(sid: sid, d: [])) }
        if cloud.tunnel === self { cloud.tunnel = nil }
        first = nil
        setStatus(.closed(reason: reason, retryable: false))
        onFrame = { _ in }
        onStatus = { _ in }
    }

    // MARK: From the app session

    /// Message 1 of the app session goes now: the box session's message 1
    /// rides inside it, if one waits.
    func takeFirst() -> CloudWire.Tun? {
        guard let d = first else { return nil }
        first = nil
        return CloudWire.Tun(sid: sid, d: d)
    }

    func receive(_ tun: CloudWire.Tun) {
        // The late end or answer of an older session.
        guard !shutdown, tun.sid == sid, sid != 0 else { return }
        guard !tun.ended else {
            end()
            return
        }
        framesThisSession += 1
        if framesThisSession == 2 { carryingSinceMs = scheduler.nowMs }
        onFrame(tun.d)
    }

    func cloudStatus(_ s: CloudCarrier.Status) {
        guard !shutdown else { return }
        switch s {
        case .open:
            // Message 1 went before the box session's was ready.
            if let d = first {
                first = nil
                cloud.sendTun(CloudWire.Tun(sid: sid, d: d))
            }
        case .closed:
            // Every box session ends with the app session that carried it.
            first = nil
        case .connecting:
            break
        }
        if case .closed(_, false) = s {
            // Nothing to come back to.
            retry?.cancel()
            retry = nil
            ended = false
        }
        if ended { return }
        setStatus(follow(s))
    }

    // MARK: Inside

    /// An empty `d`: the box dropped the session, another session of this
    /// device took its slot, the box does not hold it, or FTW Cloud had no
    /// box to give it to. The phone cannot tell which. A new session starts
    /// after a backoff that grows with each end and starts over only after
    /// a session carried for `settledMs`, so neither an absent box nor a
    /// second session of this device is asked in a loop.
    private func end() {
        first = nil
        ended = true
        if let since = carryingSinceMs, scheduler.nowMs - since >= Self.settledMs { attempt = 0 }
        carryingSinceMs = nil
        setStatus(.closed(reason: Self.endedReason, retryable: true))
        let ceiling = min(Self.backoffCapMs, Self.backoffBaseMs * pow(2, Double(attempt)))
        attempt = min(attempt + 1, 16)
        retry?.cancel()
        retry = scheduler.after(scheduler.random() * ceiling) { [weak self] in
            guard let self, !self.shutdown else { return }
            self.retry = nil
            self.ended = false
            self.setStatus(self.follow(self.cloud.status))
        }
    }

    static let endedReason = "the box ended the session"

    /// Open while the app session dials or is up: message 1 can wait for
    /// it. Closed while it waits out a backoff or has ended.
    private func follow(_ s: CloudCarrier.Status) -> CarrierStatus {
        switch s {
        case .connecting, .open:
            return .open(sinceMs: scheduler.nowMs)
        case .closed(let code, let retrying):
            return .closed(reason: Self.reason(code), retryable: retrying)
        }
    }

    nonisolated static func reason(_ code: Int) -> String {
        switch code {
        case CloudWire.closeDenied: return "FTW Cloud refused the session"
        case CloudWire.closeReplaced: return "another session took over"
        case CloudCarrier.closeNormal: return "FTW Cloud session closed"
        default: return "FTW Cloud connection lost"
        }
    }

    private func setStatus(_ next: CarrierStatus) {
        switch (status, next) {
        case (.connecting, .connecting), (.open, .open):
            return
        case let (.closed(a, x), .closed(b, y)) where a == b && x == y:
            return
        default:
            status = next
            onStatus(next)
        }
    }
}
