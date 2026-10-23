import Foundation

/// Which way a watch's command can leave, from the phone's reach and FTW
/// Cloud's. The screens hear one answer, whether a command can leave, and
/// whether the phone can be reached for what only the phone may send. Each
/// is said only when it changes, so the buttons hold still while the two
/// paths change places: a phone walking away from a watch that FTW Cloud
/// carries changes nothing on the wrist.
public struct WatchReach: Sendable {
    public private(set) var phone = false
    public private(set) var cloud = false
    private var said: (send: Bool, phone: Bool)?

    public init() {}

    /// What the screens should hear now; nothing when they already heard it.
    public enum Change: Equatable, Sendable {
        case canSend(Bool)
        case phoneReachable(Bool)
    }

    public var canSend: Bool { phone || cloud }

    public mutating func set(phone: Bool? = nil, cloud: Bool? = nil) -> [Change] {
        if let phone { self.phone = phone }
        if let cloud { self.cloud = cloud }
        var out = [Change]()
        if said?.send != canSend { out.append(.canSend(canSend)) }
        if said?.phone != self.phone { out.append(.phoneReachable(self.phone)) }
        said = (canSend, self.phone)
        return out
    }
}
