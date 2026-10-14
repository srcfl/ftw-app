import Foundation
import FTWShared
import Observation

/// The latest `capacity` values, oldest dropped first. Appending is O(1)
/// and never reallocates once full.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    /// Where the oldest element sits once the buffer is full.
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "a ring holds at least one element")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    public var elements: [Element] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count]
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// The last minutes of every live reading, kept in memory as they arrive.
/// No request and no timer: a reading lands, its values go in.
///
/// It records from the moment the home opens, from whichever source is
/// live: the box's own stream or FTW Cloud. A field goes in only while its
/// own reading is live, so a device that stopped answering draws nothing
/// rather than its last value over and over. Each point is stamped with
/// when the box took it, not when it reached the phone, so a slow network
/// or a switch between sources never bends the line.
///
/// A frame that changed nothing (`tick`) still records, because the values
/// it stands for are still true; a source that falls silent past its gap
/// rule records nothing, and the curve breaks there rather than drawing a
/// line across.
///
/// The last five minutes are sealed as `ring-<site>` with the home's other
/// files, so after a kill a node's curve opens with what the app saw
/// before. Those points are marked `restored`: drawn in ink, never as live,
/// and `resumed` dates the time the app missed.
@Observable
@MainActor
public final class LiveTrace {
    public struct Point: Equatable, Sendable {
        /// When the box took the reading, by the phone clock, in ms.
        public let t: Double
        public let v: Double
        /// Points with the same run join. A silence past the source's gap
        /// starts a new one.
        public let run: Int
        /// Kept from before this launch. Drawn in ink, never as live.
        public let restored: Bool

        public init(t: Double, v: Double, run: Int = 0, restored: Bool = false) {
            self.t = t
            self.v = v
            self.run = run
            self.restored = restored
        }

        /// The same point with another value: a node's view of it.
        public func with(v: Double) -> Point {
            Point(t: t, v: v, run: run, restored: restored)
        }
    }

    /// What a node's live curve shows.
    public nonisolated static let windowMs: Double = 5 * 60_000
    /// Ten minutes at 1 Hz. Hidden, at 0.2 Hz, the same room lasts longer,
    /// and the window still shows only the last five minutes.
    nonisolated static let capacity = 600
    /// Past this a silence in a 1 Hz stream is a gap: it misses a beat now
    /// and then, and three are a stream that stopped. Each source says its
    /// own (`SiteModel.readingGapMs`); this is the box's stream in front.
    public nonisolated static let gapMs: Double = 3_500

    /// The time between the newest restored point and the first live one
    /// after it. `toMs` is nil until a live reading comes.
    public struct Resumed: Equatable, Sendable {
        public let fromMs: Double
        public var toMs: Double?
    }

    /// Moves once per recorded reading, so a curve redraws once a second
    /// and nothing else does.
    public private(set) var revision = 0
    /// Nil when nothing was restored at launch.
    public private(set) var resumed: Resumed?

    @ObservationIgnored private var rings: [Int: RingBuffer<Point>] = [:]
    /// Per field, how long its newest point may stand before a silence is
    /// a gap, as its source said when it was taken.
    @ObservationIgnored private var holds: [Int: Double] = [:]
    @ObservationIgnored private var nextRun = 0
    @ObservationIgnored private var lastFrameAtMs: Double?
    @ObservationIgnored private weak var site: SiteModel?
    @ObservationIgnored private var token: Int?

    public init(site: SiteModel) {
        self.site = site
        if let file = site.keptFile(RingFile.self, "ring"), file.version == RingFile.version { restore(file) }
        site.keepFile("ring") { [weak self] in self?.file }
        token = site.observe { [weak self] in self?.take() }
        take()
    }

    /// For tests and the demo: a trace fed by hand.
    init() {}

    public func stop() {
        if let token { site?.unobserve(token) }
        token = nil
    }

    private func take() {
        guard let site, let at = site.lastFrameAtMs, at != lastFrameAtMs else { return }
        lastFrameAtMs = at
        guard let stamp = site.readingStampMs else { return }
        var live = [Int: Double]()
        for (fid, v) in site.session.fields where !Self.untraced.contains(fid) && site.freshness(fid: fid).live {
            live[fid] = v
        }
        guard !live.isEmpty else { return }
        record(live, atMs: stamp, gapMs: site.readingGapMs)
    }

    /// One reading's values, taken by the box at `atMs`. Only what a trace
    /// draws is kept (`untraced`). A value no newer than what the ring
    /// holds is not a new reading.
    func record(_ fields: [Int: Double], atMs: Double, gapMs: Double = LiveTrace.gapMs) {
        var any = false
        for (fid, v) in fields where !Self.untraced.contains(fid) {
            var ring = rings[fid] ?? RingBuffer(capacity: Self.capacity)
            let last = ring.last
            if let last, atMs <= last.t { continue }
            let run: Int
            if let last, !last.restored, atMs - last.t <= holds[fid, default: gapMs] {
                run = last.run
            } else {
                nextRun += 1
                run = nextRun
            }
            ring.append(Point(t: atMs, v: v, run: run))
            rings[fid] = ring
            holds[fid] = gapMs
            any = true
        }
        guard any else { return }
        if resumed != nil, resumed?.toMs == nil { resumed?.toMs = atMs }
        revision += 1
    }

    // MARK: The sealed ring

    /// The last five minutes of every ring, as the file keeps them.
    var file: RingFile? {
        guard let newest = rings.values.compactMap({ $0.last?.t }).max() else { return nil }
        var lanes = [String: RingFile.Lane]()
        for (fid, ring) in rings {
            let kept = ring.elements.filter { $0.t >= newest - Self.windowMs }
            guard let first = kept.first else { continue }
            var lane = RingFile.Lane(t0: first.t.rounded(), dt: [], v: [], starts: [])
            var previous: Point?
            for (i, p) in kept.enumerated() {
                lane.dt.append(Int(p.t.rounded() - (previous?.t.rounded() ?? lane.t0)))
                lane.v.append(p.v)
                if previous.map({ $0.run != p.run || $0.restored != p.restored }) ?? true { lane.starts.append(i) }
                previous = p
            }
            lanes[String(fid)] = lane
        }
        return RingFile(lanes: lanes)
    }

    /// What the last launch kept, as points that are no longer live.
    func restore(_ file: RingFile) {
        var newest: Double?
        for (key, lane) in file.lanes {
            guard let fid = Int(key), !Self.untraced.contains(fid), lane.dt.count == lane.v.count, !lane.v.isEmpty else { continue }
            var ring = RingBuffer<Point>(capacity: Self.capacity)
            var t = lane.t0
            for i in lane.v.indices {
                t += Double(lane.dt[i])
                if i == 0 || lane.starts.contains(i) { nextRun += 1 }
                ring.append(Point(t: t, v: lane.v[i], run: nextRun, restored: true))
            }
            rings[fid] = ring
            newest = max(newest ?? t, t)
        }
        if let newest { resumed = Resumed(fromMs: newest, toMs: nil) }
    }

    /// Not kept: the mode and the source references are not readings, the
    /// fuse is config, and the phases are drawn as meters of now, never as
    /// a trace.
    nonisolated static let untraced: Set<Int> = Set([Contract.FID.mode, Contract.FID.srcGrid, Contract.FID.srcPV, Contract.FID.srcBattery, Contract.FID.gridFuseDA] + Contract.FID.gridPhases)

    /// The time the app missed, while restored points still show in the
    /// window that ends at `nowMs`.
    public func missed(nowMs: Double) -> Resumed? {
        guard let resumed, resumed.fromMs >= nowMs - Self.windowMs else { return nil }
        return resumed
    }

    /// One field from `sinceMs` on, oldest first.
    public func points(_ fid: Int, sinceMs: Double) -> [Point] {
        _ = revision
        return (rings[fid]?.elements ?? []).filter { $0.t >= sinceMs }
    }

    /// One node's readings as its trace draws them: solar as what it makes,
    /// and a point kept from before this launch not seen live.
    public func samples(_ node: EnergyNode, sinceMs: Double) -> [LiveSample] {
        points(node.fid, sinceMs: sinceMs).map { LiveSample(t: $0.t, v: node.shown($0.v), seen: !$0.restored) }
    }

    /// Where the curve breaks: each run numbered from zero in order, so a
    /// chart draws one line per run.
    public nonisolated static func runs(_ points: [Point]) -> [(run: Int, point: Point)] {
        var out = [(run: Int, point: Point)]()
        out.reserveCapacity(points.count)
        var run = 0
        var previous: Point?
        for p in points {
            if let previous, previous.run != p.run || previous.restored != p.restored { run += 1 }
            out.append((run, p))
            previous = p
        }
        return out
    }
}

/// The live rings as `ring-<site>` keeps them: per field, times as steps in
/// whole ms after the first, the values, and where each run starts. About
/// 15 KB for five minutes of Now's fields.
struct RingFile: Codable, Equatable, Sendable {
    static let version = 1

    struct Lane: Codable, Equatable, Sendable {
        var t0: Double
        /// Each point's time after the one before; the first is 0.
        var dt: [Int]
        var v: [Double]
        /// The indexes where a run starts.
        var starts: [Int]
    }

    var version = RingFile.version
    /// By field id.
    var lanes: [String: Lane]
}
