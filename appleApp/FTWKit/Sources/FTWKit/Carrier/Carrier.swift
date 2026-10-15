import Foundation
import FTWShared

public enum CarrierStatus: Equatable, Sendable {
    case connecting
    case open(sinceMs: Double)
    case closed(reason: String, retryable: Bool)

    public var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    /// The relay turned this phone away with 4429: the home already has as
    /// many phones watching as the relay serves, or the relay is shedding
    /// load. Someone else is looking; nothing is broken.
    public var isBusy: Bool {
        if case .closed(let reason, _) = self { return reason == RelayCarrier.closeReason(RelayCarrier.closeBusy) }
        return false
    }

    var phaseName: String {
        switch self {
        case .connecting: return "connecting"
        case .open: return "open"
        case .closed: return "closed"
        }
    }
}

/// Moves opaque frames and nothing else. It cannot read a frame and has no
/// opinion about the protocol, so a LAN path can be added later as one more
/// implementation without a line changing above this.
@MainActor
public protocol Carrier: AnyObject {
    var kind: CarrierKind { get }
    var status: CarrierStatus { get }
    /// Whether the frame went out. A carrier that is not open drops it and
    /// says so, so a command can fail at once instead of waiting out a
    /// deadline for an answer that cannot come.
    @discardableResult
    func send(_ frame: Bytes) -> Bool
    /// Replaces the handlers. One owner at a time: the carrier stack is
    /// built as a chain, each layer owning the one below it.
    func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void)
    /// Recheck the live path after the app or network wakes. Frames are
    /// never replayed.
    func wake()
    func close(reason: String)
    /// A new session with the box starts here: the next frame is its
    /// handshake message 1. A carrier that names sessions on the wire draws
    /// a new name; one that does not ignores it.
    func beginSession()
}

extension Carrier {
    public func beginSession() {}
}

// MARK: - WebSockets

/// The socket underneath the relay carrier, reduced to what it uses.
@MainActor
public protocol WebSocketConnection: AnyObject {
    func send(_ data: Bytes)
    func close()
    /// How it travels, by the registry's `cloud_transports`.
    var transportName: String { get }
}

extension WebSocketConnection {
    public var transportName: String { Contract.transportWebSocket }
}

@MainActor
public struct WebSocketEvents {
    public var onOpen: @MainActor () -> Void
    public var onText: @MainActor (String) -> Void
    public var onBinary: @MainActor (Bytes) -> Void
    /// Close code and reason. A socket that failed to open closes with 1006.
    public var onClose: @MainActor (Int, String) -> Void
}

public typealias WebSocketFactory = @MainActor (_ url: URL, _ events: WebSocketEvents) -> WebSocketConnection
