import Foundation

// What the iPhone and its Apple Watch say to each other over
// WatchConnectivity. The watch cannot open the relay (TN3135: no WebSocket
// and no Network connections for an ordinary watch app), and it holds no
// key. So the phone sends it the same records its widgets read, and the
// watch sends back intent. The phone runs every command over its own
// session with the box, and the box decides.
//
// Plain values, so the app, the watch, its widgets and a test all read the
// same rules.

/// Now as the phone last read it: one reading per node, whether FTW is in
/// control, and how the home is run. Kept on the watch like any other
/// record, so it reads back as `.cache` and never glows.
public struct WatchNow: CacheValue {
    public static let name = "now"
    public static let version = 1

    public enum Node: String, Codable, Sendable, CaseIterable {
        case solar, battery, home, grid, car

        /// The least a trace's scale reaches, as the phone's node view has
        /// it (`EnergyNode.scaleFloorW`), so a quiet node draws flat.
        public var floorW: Double {
            switch self {
            case .home: return 2_000
            case .grid, .battery, .solar: return 3_000
            case .car: return 3_700
            }
        }
    }

    /// The word beside a figure. The sign is in the word, never a minus.
    public enum Way: String, Codable, Sendable {
        case making, resting, charging, giving, using, buying, selling, balanced, noReading
    }

    public struct Reading: Codable, Sendable, Equatable {
        public var node: Node
        /// Watts as shown, never signed. Nil when the box sends no field.
        public var watts: Double?
        public var way: Way
        /// The battery's charge or the car's level, whole percent.
        public var levelPct: Double?
        /// The car's level is FTW's assumption, not a reading.
        public var levelAssumed: Bool
        /// The phone saw this reading live: a live carrier and its own
        /// source live. The watch adds its own rule on arrival.
        public var live: Bool

        /// The watts with their direction as a trace draws them: the sun's
        /// output, the home's use and the car's draw up; the battery up
        /// while it stores and down while it gives; the grid up while the
        /// home buys and down while it sells.
        public var signedW: Double? {
            guard let watts else { return nil }
            switch way {
            case .giving, .selling: return -watts
            default: return watts
            }
        }

        public init(node: Node, watts: Double?, way: Way, levelPct: Double? = nil, levelAssumed: Bool = false, live: Bool) {
            self.node = node
            self.watts = watts
            self.way = way
            self.levelPct = levelPct
            self.levelAssumed = levelAssumed
            self.live = live
        }
    }

    public enum Control: String, Codable, Sendable {
        case inControl, notInControl, unknown
    }

    public var readings: [Reading]
    public var control: Control

    public init(readings: [Reading], control: Control) {
        self.readings = readings
        self.control = control
    }

    public func reading(_ node: Node) -> Reading? { readings.first { $0.node == node } }
}

/// How the home is run, and what the watch may ask for: the box's modes in
/// its order, the one it reports, and whether this phone may change it.
public struct WatchModes: Codable, Sendable, Equatable {
    public struct Mode: Codable, Sendable, Equatable, Identifiable {
        public var key: String
        /// The mode's name in the phone's language.
        public var name: String
        /// One of the planner's modes: "Use the plan".
        public var isPlan: Bool
        public var id: String { key }

        public init(key: String, name: String, isPlan: Bool) {
            self.key = key
            self.name = name
            self.isPlan = isPlan
        }
    }

    public var modes: [Mode]
    /// The mode the box reported when the phone wrote this.
    public var shown: String?
    /// "Plan · Balanced", or a manual mode's name.
    public var label: String?
    /// The box offers dispatch and this phone's grant carries the scope.
    public var mayControl: Bool

    public init(modes: [Mode], shown: String?, label: String?, mayControl: Bool) {
        self.modes = modes
        self.shown = shown
        self.label = label
        self.mayControl = mayControl
    }
}

/// Everything the watch shows, as one value the phone replaces whenever it
/// writes its cache (`updateApplicationContext`). Each record keeps where it
/// came from and when, as in the App Group.
public struct WatchContext: Codable, Sendable, Equatable {
    public static let version = 1
    /// The key in the application context and the complication's user info.
    public static let key = "ctx"

    public var version: Int
    /// The site, or "demo" for the simulated home. Empty: the phone has no
    /// home, and the watch forgets the one it had.
    public var home: String
    public var isDemo: Bool
    public var prices: CacheRecord<PriceEntry>?
    public var cars: CacheRecord<CarEntry>?
    public var plan: CacheRecord<PlanEntry>?
    public var now: CacheRecord<WatchNow>?
    public var modes: WatchModes?
    /// The last command from the watch, as far as the box has answered it,
    /// so a watch that slept meanwhile still sees how it ended.
    public var receipt: WatchReceipt?
    /// Phone clock when the phone sent this.
    public var sentAtMs: Double

    public init(home: String, isDemo: Bool, prices: CacheRecord<PriceEntry>? = nil, cars: CacheRecord<CarEntry>? = nil, plan: CacheRecord<PlanEntry>? = nil, now: CacheRecord<WatchNow>? = nil, modes: WatchModes? = nil, receipt: WatchReceipt? = nil, sentAtMs: Double) {
        version = Self.version
        self.home = home
        self.isDemo = isDemo
        self.prices = prices
        self.cars = cars
        self.plan = plan
        self.now = now
        self.modes = modes
        self.receipt = receipt
        self.sentAtMs = sentAtMs
    }

    /// The phone has signed out, or never paired.
    public static func empty(sentAtMs: Double) -> WatchContext {
        WatchContext(home: "", isDemo: false, sentAtMs: sentAtMs)
    }

    public var hasHome: Bool { !home.isEmpty }

    /// The same records, whenever the phone sent them. A resend of this
    /// tells the watch nothing new.
    public func sameAs(_ other: WatchContext) -> Bool {
        var a = self, b = other
        a.sentAtMs = 0
        b.sentAtMs = 0
        return a == b
    }

    /// JSON, then LZFSE: a day of quarters for the plan and the prices is
    /// tens of kilobytes as JSON and a few once packed.
    public func packed() throws -> Data {
        try (JSONEncoder().encode(self) as NSData).compressed(using: .lzfse) as Data
    }

    /// Nil for anything this build cannot read: another version, or bytes
    /// that are not a context.
    public static func unpacked(_ data: Data) -> WatchContext? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let ctx = try? JSONDecoder().decode(WatchContext.self, from: json),
              ctx.version == version else { return nil }
        return ctx
    }
}

/// A command from the watch: what to do, to which home, and until when it
/// still means something. The phone builds the box's `cmd` and checks the
/// home and the time; the watch never names an op the box knows.
///
/// The watch makes the `cmdId`, a UUIDv7 as the phone's own are, and the
/// phone sends the box that id. When the watch can also reach the box
/// itself (ADR 0009), a command tried both ways still runs once.
public struct WatchCommand: Codable, Sendable, Equatable, Identifiable {
    public enum Op: Codable, Sendable, Equatable {
        case chargeNow(loadpointID: String)
        case pause(loadpointID: String)
        case backToPlan(loadpointID: String)
        case mode(String)
    }

    /// How long a command stays worth running. A tap that reaches the
    /// phone later than this is dropped, not run late.
    public static let lifeMs: Double = 30_000

    /// The box's `cmdId`.
    public var id: String
    public var op: Op
    /// The home the watch showed when it was tapped.
    public var home: String
    public var notValidAfterMs: Double

    public init(id: String? = nil, op: Op, home: String, sentAtMs: Double) {
        self.id = id ?? Self.newID(nowMs: sentAtMs)
        self.op = op
        self.home = home
        notValidAfterMs = sentAtMs + Self.lifeMs
    }

    /// A UUIDv7: the time in its first 48 bits, the rest random.
    public static func newID(nowMs: Double) -> String {
        var g = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
        let ms = UInt64(max(0, nowMs))
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: ms >> UInt64(8 * (5 - i))) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let h = Array(bytes.map { String(format: "%02x", $0) }.joined())
        return "\(String(h[0..<8]))-\(String(h[8..<12]))-\(String(h[12..<16]))-\(String(h[16..<20]))-\(String(h[20...]))"
    }

    /// Whether `id` is a UUIDv7 written the way the box expects: lower
    /// case, with its version and variant bits. The phone sends nothing
    /// else as a `cmdId`.
    public static func isID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12], id.allSatisfy({ $0 == "-" || $0.isHexDigit && !$0.isUppercase }) else { return false }
        return parts[2].first == "7" && "89ab".contains(parts[3].first!)
    }
}

/// What the watch says to the phone (`sendMessageData`).
public enum WatchAsk: Codable, Sendable, Equatable {
    /// The watch app is on screen: send Now while it looks.
    case look
    /// It left the screen.
    case away
    case command(WatchCommand)

    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func from(_ data: Data) -> WatchAsk? { try? JSONDecoder().decode(WatchAsk.self, from: data) }
}

/// What the phone says to the watch while the watch app is on screen.
public enum WatchNews: Codable, Sendable, Equatable {
    case now(CacheRecord<WatchNow>)
    case receipt(WatchReceipt)

    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func from(_ data: Data) -> WatchNews? { try? JSONDecoder().decode(WatchNews.self, from: data) }
}

/// How far a command from the watch has come: SENT ▸ ACCEPTED ▸ CONFIRMED.
///
/// Sent is the phone sending the box's `cmd`, accepted the box's
/// `cmd.ack`, confirmed its `cmd.result`. The phone fills every mark from
/// the box's answers. The watch itself can only say that it is sending,
/// that the phone could not be reached, or that no answer came, so it can
/// never show a result the box has not confirmed.
public struct WatchReceipt: Codable, Sendable, Equatable {
    public enum Mark: String, Codable, Sendable {
        case waiting, active, done, failed
    }

    public enum Tone: String, Codable, Sendable {
        case working, done, warning, failed
    }

    public var commandID: String
    public var op: WatchCommand.Op
    public var sent: Mark
    public var accepted: Mark
    public var confirmed: Mark
    /// One sentence, ready to show.
    public var text: String
    public var tone: Tone

    public init(commandID: String, op: WatchCommand.Op, sent: Mark, accepted: Mark, confirmed: Mark, text: String, tone: Tone) {
        self.commandID = commandID
        self.op = op
        self.sent = sent
        self.accepted = accepted
        self.confirmed = confirmed
        self.text = text
        self.tone = tone
    }

    /// The command has settled, one way or the other.
    public var settled: Bool { tone != .working }

    /// How long the watch waits for the phone before it says no answer
    /// came. The box has 20 s to answer and the phone needs a moment to
    /// wake and connect.
    public static let answerMs: Double = 45_000

    /// At the tap: on its way to the phone.
    public static func tapped(_ c: WatchCommand) -> WatchReceipt {
        WatchReceipt(commandID: c.id, op: c.op, sent: .active, accepted: .waiting, confirmed: .waiting, text: WatchWord.sendingToPhone.text, tone: .working)
    }

    /// The phone has the command and is sending it to the box.
    public static func phoneHasIt(_ c: WatchCommand) -> WatchReceipt {
        WatchReceipt(commandID: c.id, op: c.op, sent: .active, accepted: .waiting, confirmed: .waiting, text: WatchWord.phoneSending.text, tone: .working)
    }

    /// The phone could not be reached: nothing went to the box.
    public static func unreachable(_ c: WatchCommand) -> WatchReceipt {
        WatchReceipt(commandID: c.id, op: c.op, sent: .failed, accepted: .waiting, confirmed: .waiting, text: WatchWord.phoneUnreachableNothingSent.text, tone: .failed)
    }

    /// No word from the phone within `answerMs`. It may still have run, so
    /// this is a warning, and the marks stay as the phone last left them.
    public func noAnswer() -> WatchReceipt {
        guard !settled else { return self }
        var r = self
        if r.sent == .active { r.sent = .waiting }
        r.text = WatchWord.noAnswerCheckPhone.text
        r.tone = .warning
        return r
    }

    /// What to show once `next` arrives. Another command's receipt is not
    /// this one's, and a settled receipt keeps its end.
    public func taking(_ next: WatchReceipt) -> WatchReceipt? {
        guard next.commandID == commandID else { return nil }
        if settled, next.tone == .working { return nil }
        return next
    }
}

extension PriceEntry {
    /// Whether `new` brings a day `old` did not have: it reaches past the
    /// end of today on the household clock, and further than before. The
    /// phone then wakes the watch's complication, which may do so only 50
    /// times a day.
    public static func bringsNewDay(old: PriceEntry?, new: PriceEntry?, nowMs: Double) -> Bool {
        guard let new, let newEnd = new.prices.slots.map({ $0.startMs + $0.durationMs }).max() else { return false }
        let oldEnd = old?.prices.slots.map { $0.startMs + $0.durationMs }.max() ?? 0
        let calendar = Calendar.household(new.timeZone)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        let midnight = tomorrow.timeIntervalSince1970 * 1000
        return newEnd > midnight && newEnd > oldEnd && oldEnd <= midnight
    }
}
