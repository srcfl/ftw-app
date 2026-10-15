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

        /// The least a trace's scale reaches, so a quiet node draws flat: a
        /// quarter of the phone's (`EnergyNode.scaleFloorW`), because the
        /// wrist's trace is about a quarter as tall. Noise of 60 W then
        /// spreads as few points as on the phone, and a home using 400 W
        /// fills the trace rather than hugging its floor.
        public var floorW: Double {
            switch self {
            case .home: return 500
            case .grid, .battery, .solar: return 750
            case .car: return 925
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
    /// How long the phone itself counts this reading live with no newer
    /// one: its stream's gap rule (3.5 s at 1 Hz, longer for a slower
    /// stream or FTW Cloud). The watch glows no longer than this and the
    /// hop. Nil from a phone before 0.4.4.
    public var standsMs: Double?

    public init(readings: [Reading], control: Control, standsMs: Double? = nil) {
        self.readings = readings
        self.control = control
        self.standsMs = standsMs
    }

    public func reading(_ node: Node) -> Reading? { readings.first { $0.node == node } }

    /// Now's shape, drawn redacted while nothing is known. Never shown as
    /// a reading.
    public static let shape = WatchNow(readings: [
        Reading(node: .home, watts: 1_500, way: .using, live: false),
        Reading(node: .solar, watts: 2_000, way: .making, live: false),
        Reading(node: .battery, watts: 1_000, way: .charging, levelPct: 50, live: false),
        Reading(node: .grid, watts: 500, way: .buying, live: false),
        Reading(node: .car, watts: 0, way: .resting, live: false),
    ], control: .unknown)
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
    /// The last minutes of Now's trace, as this watch last drew them. The
    /// watch keeps them here for its next open; the phone never fills it
    /// and sends its own with the reply to `.look` (`WatchNews.recent`).
    public var recent: WatchRecent?
    /// The phone signed out, or was never paired, and says so. A context
    /// with no home that does not say so comes from a phone still opening
    /// its home, and changes nothing on the watch.
    public var signedOut: Bool?
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

    /// The phone has signed out, or never paired: the watch forgets the
    /// home and everything it kept of it.
    public static func signOut(sentAtMs: Double) -> WatchContext {
        var ctx = WatchContext(home: "", isDemo: false, sentAtMs: sentAtMs)
        ctx.signedOut = true
        return ctx
    }

    /// The phone has a home but has not opened it yet: nothing to show,
    /// and nothing for the watch to forget.
    public static func opening(sentAtMs: Double) -> WatchContext {
        WatchContext(home: "", isDemo: false, sentAtMs: sentAtMs)
    }

    public var hasHome: Bool { !home.isEmpty }

    /// What the watch keeps once `next` arrives over `kept`. Only an
    /// explicit sign-out forgets; a phone still opening its home changes
    /// nothing; another home replaces the whole. For the same home each
    /// record is the newer of the two, and one the phone did not send keeps
    /// the old: a phone that has not read its prices yet since it opened
    /// does not take them off the wrist. The dial keeps the last sun the
    /// box forecast until a newer forecast comes. Nil: nothing to keep.
    public static func merging(_ next: WatchContext, over kept: WatchContext?) -> WatchContext? {
        if next.signedOut == true { return next }
        guard next.hasHome else { return kept }
        guard let kept, kept.home == next.home else { return next }
        var out = next
        out.prices = newer(kept.prices, next.prices)
        out.cars = newer(kept.cars, next.cars)
        out.plan = newer(kept.plan, next.plan)
        out.now = newer(kept.now, next.now)
        out.modes = next.modes ?? kept.modes
        out.receipt = next.receipt ?? kept.receipt
        if (kept.recent?.newestMs ?? 0) > (next.recent?.newestMs ?? 0) { out.recent = kept.recent }
        if out.plan != nil, out.plan?.value.daylight == nil { out.plan?.value.daylight = kept.plan?.value.daylight }
        return out
    }

    private static func newer<Value>(_ kept: CacheRecord<Value>?, _ next: CacheRecord<Value>?) -> CacheRecord<Value>? {
        guard let kept else { return next }
        guard let next else { return kept }
        return next.readAtMs >= kept.readAtMs ? next : kept
    }

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

/// The last minutes of each node as the phone recorded them, sent with its
/// reply to `.look` so the watch's trace opens whole, and kept by the watch
/// for its next open. The watch saw none of it live, so it draws it in ink.
///
/// On the wire as one packed blob, JSON then LZFSE as the context is: three
/// minutes of five nodes at 1 Hz come to about 3 KB. A window that would
/// not fit `maxBytes` keeps every other reading until it does.
public struct WatchRecent: Sendable, Equatable {
    /// The width of the watch's trace.
    public static let windowMs: Double = 3 * 60_000
    /// The most one reply to `.look` carries, as the phone sends it.
    public static let maxBytes = 8_192

    public struct Lane: Codable, Sendable, Equatable {
        public var node: WatchNow.Node
        /// The first reading's time by the phone clock, in whole ms.
        public var t0: Double
        /// Each reading's time after the one before, in ms; the first is 0.
        public var dt: [Int]
        /// Whole watts, in the direction the trace draws them
        /// (`WatchNow.Reading.signedW`).
        public var w: [Int]

        public init(node: WatchNow.Node, samples: [LiveSample]) {
            self.node = node
            t0 = samples.first?.t.rounded() ?? 0
            var last = t0
            dt = samples.map { s in
                let t = s.t.rounded()
                defer { last = t }
                return Int(t - last)
            }
            w = samples.map { Int($0.v.rounded()) }
        }

        /// Not seen live on this watch: drawn in ink.
        public var samples: [LiveSample] {
            var t = t0
            return zip(dt, w).map { step, watts in
                t += Double(step)
                return LiveSample(t: t, v: Double(watts), seen: false)
            }
        }

        /// Every other reading, the last one kept.
        func thinned() -> Lane {
            let all = samples
            let keep = all.indices.filter { ($0 - all.count + 1) % 2 == 0 }
            return Lane(node: node, samples: keep.map { all[$0] })
        }
    }

    public var lanes: [Lane]

    public init(lanes: [Lane]) {
        self.lanes = lanes
    }

    /// Each node's readings in the window that ends at `nowMs`, thinned
    /// until one reply carries them.
    public static func make(_ samples: [WatchNow.Node: [LiveSample]], nowMs: Double) -> WatchRecent {
        let from = nowMs - windowMs
        var recent = WatchRecent(lanes: WatchNow.Node.allCases.compactMap { node in
            let kept = (samples[node] ?? []).filter { $0.t >= from && $0.t <= nowMs }
            return kept.isEmpty ? nil : Lane(node: node, samples: kept)
        })
        while recent.wireBytes > maxBytes {
            guard recent.lanes.contains(where: { $0.w.count > 2 }) else { return WatchRecent(lanes: []) }
            recent.lanes = recent.lanes.map { $0.thinned() }
        }
        return recent
    }

    public func samples(_ node: WatchNow.Node) -> [LiveSample] {
        lanes.first { $0.node == node }?.samples ?? []
    }

    /// The newest reading in any lane.
    public var newestMs: Double? {
        lanes.compactMap { lane in lane.dt.isEmpty ? nil : lane.t0 + Double(lane.dt.reduce(0, +)) }.max()
    }

    /// The bytes the phone sends: the whole message, as `WatchNews`.
    public var wireBytes: Int {
        (try? WatchNews.recent(self).data().count) ?? .max
    }
}

extension WatchRecent: Codable {
    public init(from decoder: Decoder) throws {
        let packed = try decoder.singleValueContainer().decode(Data.self)
        guard let json = try? (packed as NSData).decompressed(using: .lzfse) as Data else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a packed trace"))
        }
        lanes = try JSONDecoder().decode([Lane].self, from: json)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(try (JSONEncoder().encode(lanes) as NSData).compressed(using: .lzfse) as Data)
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
    /// The last three minutes of each node, with the reply to `.look`, so
    /// the trace opens whole rather than growing from one dot.
    case recent(WatchRecent)

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
