import Foundation

// FTWShared is what the app shares with its widgets, and later with a
// notification extension. Every type here is a plain `Sendable` value with
// no main actor, so an extension can read it without the app's session.
//
// The names below are the registry's `carrier_states` and `source_states`,
// checked by `ContractTests`.

/// How frames are reaching us. Orthogonal to `SourceState`, never merged
/// with it: "connected, but the inverter went quiet 40 seconds ago" needs
/// both.
public enum CarrierKind: String, Sendable, Codable {
    /// `cloud` is data read through FTW Cloud, signed by the box.
    case webrtc, relay, cloud, cache, none
}

public enum SourceState: String, Sendable, Codable, Comparable {
    case live, lagging, stale, down, never

    var rank: Int {
        switch self {
        case .live: return 0
        case .lagging: return 1
        case .stale: return 2
        case .down: return 3
        case .never: return 4
        }
    }

    public static func < (a: SourceState, b: SourceState) -> Bool { a.rank < b.rank }
}

/// Where the session is between a carrier and a stream.
public enum SessionPhase: String, Sendable {
    case idle, handshaking, subscribing, streaming, booting, terminated, failed
}
