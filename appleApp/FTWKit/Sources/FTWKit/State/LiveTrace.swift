import Foundation
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

    /// Moves once per recorded reading, so a curve redraws once a second
    /// and nothing else does.
    public private(set) var revision = 0

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
        for (fid, v) in site.session.fields where !Self.notReadings.contains(fid) && site.freshness(fid: fid).live {
            live[fid] = v
        }
        guard !live.isEmpty else { return }
        record(live, atMs: stamp, gapMs: site.readingGapMs)
    }

    /// One reading's values, taken by the box at `atMs`. The mode and the
    /// source references are not readings and are not kept. A value no
    /// newer than what the ring holds is not a new reading.
    func record(_ fields: [Int: Double], atMs: Double, gapMs: Double = LiveTrace.gapMs) {
        var any = false
        for (fid, v) in fields where !Self.notReadings.contains(fid) {
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
        if any { revision += 1 }
    }

    nonisolated static let notReadings: Set<Int> = [Contract.FID.mode, Contract.FID.srcGrid, Contract.FID.srcPV, Contract.FID.srcBattery]

    /// One field from `sinceMs` on, oldest first.
    public func points(_ fid: Int, sinceMs: Double) -> [Point] {
        _ = revision
        return (rings[fid]?.elements ?? []).filter { $0.t >= sinceMs }
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
