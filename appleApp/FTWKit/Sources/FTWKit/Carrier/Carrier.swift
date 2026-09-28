import Foundation

/// How frames are reaching us. Orthogonal to `SourceState`, never merged
/// with it: "connected, but the inverter went quiet 40 seconds ago" needs
/// both.
public enum CarrierKind: String, Sendable, Codable {
    case webrtc, relay, cache, none
}

public enum CarrierStatus: Equatable, Sendable {
    case connecting
    case open(sinceMs: Double)
    case closed(reason: String, retryable: Bool)

    public var isOpen: Bool {
        if case .open = self { return true }
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
    func send(_ frame: Bytes)
    /// Replaces the handlers. One owner at a time: the carrier stack is
    /// built as a chain, each layer owning the one below it.
    func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void)
    /// Recheck the live path after the app or network wakes. Frames are
    /// never replayed.
    func wake()
    func close(reason: String)
}

// MARK: - WebSockets

/// The socket underneath the relay carrier, reduced to what it uses.
@MainActor
public protocol WebSocketConnection: AnyObject {
    func send(_ data: Bytes)
    func close()
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
