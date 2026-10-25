import Foundation

/// Which way each of the watch's commands goes, and when it reads FTW
/// Cloud, as plain rules the watch's `PathChooser` follows (srcfl/ftw ADR
/// 0009, "Through FTW Cloud"). It holds no clock and no carrier: the caller
/// says what happened and does what it is told.
///
/// A command goes by the phone when the phone can be reached. It stays the
/// phone's until the box's ack comes back through it. If the phone says it
/// could not send it, or has not passed on the box's ack within
/// `phoneTakesMs`, FTW Cloud carries it too, under the same `cmdId`, and
/// the box acts on it once. A command FTW Cloud carries is not undone by
/// the phone's word that it could not.
///
/// Every time is on one monotonic clock, the caller's. A command lives
/// `WatchCommand.lifeMs` from its tap, whatever the wall clock does.
public struct WatchRoute: Sendable {
    /// How long the phone has to pass on the box's ack before FTW Cloud
    /// carries the command too. A phone simulator says it can be reached
    /// when it is off, and a real phone can be slow to wake.
    public static let phoneTakesMs: Double = 3_000
    /// How long the phone has to answer a look before FTW Cloud is read.
    public static let phoneWaitMs: Double = 2_500

    /// Commands waiting for the box's ack through the phone.
    private var viaPhone: [String: WatchCommand] = [:]
    /// When each command was tapped.
    private var tappedAtMs: [String: Double] = [:]
    /// Commands FTW Cloud carries.
    private var viaCloud: Set<String> = []
    /// The watch app is on screen.
    public private(set) var looking = false
    private var lookedAtMs: Double = 0
    private var phoneHeardAtMs: Double = -.infinity

    public init() {}

    /// A command FTW Cloud carries, and how much of its life is left.
    public struct Carry: Equatable, Sendable {
        public var command: WatchCommand
        public var leftMs: Double
    }

    /// Where a command goes.
    public enum Go: Equatable, Sendable {
        /// By the phone; ask `phoneSlow` after `phoneTakesMs`.
        case phone
        case cloud(Carry)
        /// Neither path can carry it: nothing is sent.
        case nowhere
    }

    /// FTW Cloud carries the charger's commands alone. Which car is on a
    /// charger needs an owner's session, which only the phone has; the
    /// mode changes in Plan on the phone, never from the watch.
    public static func cloudCarries(_ c: WatchCommand) -> Bool {
        switch c.op {
        case .chargeNow, .pause, .backToPlan: return true
        case .mode, .chooseCar: return false
        }
    }

    /// The tap: where `c` goes first.
    public mutating func send(_ c: WatchCommand, phone: Bool, cloud: Bool, nowMs: Double) -> Go {
        tappedAtMs[c.id] = nowMs
        if phone {
            viaPhone[c.id] = c
            return .phone
        }
        if let carry = takeOver(c, cloud: cloud, nowMs: nowMs) { return .cloud(carry) }
        return .nowhere
    }

    /// The phone's receipt for a command. The command FTW Cloud should now
    /// carry, when the phone said it could not send it.
    public mutating func phoneSaid(_ r: WatchReceipt, cloud: Bool, nowMs: Double) -> Carry? {
        guard let c = viaPhone[r.commandID] else { return nil }
        if r.accepted == .done || r.confirmed == .done {
            // The box has it, through the phone.
            viaPhone[r.commandID] = nil
            return nil
        }
        guard r.sent == .failed else { return nil }
        viaPhone[r.commandID] = nil
        return takeOver(c, cloud: cloud, nowMs: nowMs)
    }

    /// `phoneTakesMs` after sending by the phone: FTW Cloud carries the
    /// command too if the box's ack has not come back through the phone.
    public mutating func phoneSlow(_ id: String, cloud: Bool, nowMs: Double) -> Carry? {
        guard let c = viaPhone.removeValue(forKey: id) else { return nil }
        return takeOver(c, cloud: cloud, nowMs: nowMs)
    }

    /// The phone could not be reached for a command. FTW Cloud carries it
    /// when it can; `tell` says whether the screen should hear that nothing
    /// was sent.
    public mutating func phoneNotSent(_ id: String, cloud: Bool, nowMs: Double) -> (carry: Carry?, tell: Bool) {
        if let c = viaPhone.removeValue(forKey: id), let carry = takeOver(c, cloud: cloud, nowMs: nowMs) {
            return (carry, false)
        }
        return (nil, !viaCloud.contains(id))
    }

    /// Whether a receipt the phone sends reaches the screen. Its word that
    /// it could not send a command FTW Cloud carries does not.
    public func shows(_ r: WatchReceipt) -> Bool {
        !(viaCloud.contains(r.commandID) && r.sent == .failed)
    }

    /// FTW Cloud carries `c` from now, if it can and the command has life
    /// left.
    private mutating func takeOver(_ c: WatchCommand, cloud: Bool, nowMs: Double) -> Carry? {
        let left = WatchCommand.lifeMs - (nowMs - (tappedAtMs[c.id] ?? nowMs))
        guard cloud, Self.cloudCarries(c), left > 0 else { return nil }
        viaCloud.insert(c.id)
        return Carry(command: c, leftMs: left)
    }

    // MARK: Reading

    /// The watch app came on screen, or says again that it looks. On the
    /// first look, how long to wait before reading FTW Cloud: at once when
    /// the phone cannot be reached, `phoneWaitMs` when it can. Nil on a look
    /// while already looking: FTW Cloud is read once per appearance.
    public mutating func look(phone: Bool, nowMs: Double) -> Double? {
        guard !looking else { return nil }
        looking = true
        lookedAtMs = nowMs
        return phone ? Self.phoneWaitMs : 0
    }

    public mutating func away() {
        looking = false
    }

    /// The phone sent a frame or a receipt: it answers. The context it
    /// left before the watch app started is no answer.
    public mutating func heardPhone(nowMs: Double) {
        phoneHeardAtMs = nowMs
    }

    /// Whether to read FTW Cloud now, the wait after a look over: still on
    /// screen, and the phone has not answered since the look.
    public var readsCloud: Bool {
        looking && phoneHeardAtMs < lookedAtMs
    }
}
