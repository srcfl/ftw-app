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

/// The last minutes of every reading lane 0 carries, kept in memory as the
/// frames arrive. No request and no timer: a frame lands, its values go in.
///
/// It records from the moment the home opens, so a node's live curve opens
/// already drawn. A frame that changed nothing (`tick`) still records, because
/// the values it stands for are still true; a stream that stops records
/// nothing, and the curve breaks there rather than drawing a line across.
@Observable
@MainActor
public final class LiveTrace {
    public struct Point: Equatable, Sendable {
        /// The phone's clock when the frame arrived, in ms.
        public let t: Double
        public let v: Double

        public init(t: Double, v: Double) {
            self.t = t
            self.v = v
        }
    }

    /// What a node's live curve shows.
    public nonisolated static let windowMs: Double = 5 * 60_000
    /// Ten minutes at 1 Hz. Hidden, at 0.2 Hz, the same room lasts longer,
    /// and the window still shows only the last five minutes.
    nonisolated static let capacity = 600
    /// Past this a silence is a gap: the 1 Hz stream misses a beat now and
    /// then, and three are a stream that stopped.
    public nonisolated static let gapMs: Double = 3_500

    /// Moves once per recorded frame, so a curve redraws once a second and
    /// nothing else does.
    public private(set) var revision = 0

    @ObservationIgnored private var rings: [Int: RingBuffer<Point>] = [:]
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
        guard let site, site.session.phase == .streaming, let at = site.lastFrameAtMs, at != lastFrameAtMs else { return }
        lastFrameAtMs = at
        record(site.session.fields, atMs: at)
    }

    /// One frame's values. The mode and the source references are not
    /// readings and are not kept.
    func record(_ fields: [Int: Double], atMs: Double) {
        for (fid, v) in fields where !Self.notReadings.contains(fid) {
            rings[fid, default: RingBuffer(capacity: Self.capacity)].append(Point(t: atMs, v: v))
        }
        revision += 1
    }

    nonisolated static let notReadings: Set<Int> = [Contract.FID.mode, Contract.FID.srcGrid, Contract.FID.srcPV, Contract.FID.srcBattery]

    /// One field from `sinceMs` on, oldest first.
    public func points(_ fid: Int, sinceMs: Double) -> [Point] {
        _ = revision
        return (rings[fid]?.elements ?? []).filter { $0.t >= sinceMs }
    }

    /// Several fields summed sample by sample, for a node that stands for
    /// more than one field. A sample missing any of them is left out.
    public func sum(_ fids: [Int], sinceMs: Double) -> [Point] {
        guard let first = fids.first else { return [] }
        if fids.count == 1 { return points(first, sinceMs: sinceMs) }
        var byTime = [Double: (n: Int, v: Double)]()
        for fid in fids {
            for p in points(fid, sinceMs: sinceMs) {
                let e = byTime[p.t, default: (0, 0)]
                byTime[p.t] = (e.n + 1, e.v + p.v)
            }
        }
        return byTime.filter { $0.value.n == fids.count }.map { Point(t: $0.key, v: $0.value.v) }.sorted { $0.t < $1.t }
    }

    /// Where the curve breaks: each run of samples no further apart than
    /// `gapMs`, numbered, so a chart draws one line per run.
    public nonisolated static func runs(_ points: [Point]) -> [(run: Int, point: Point)] {
        var out = [(run: Int, point: Point)]()
        out.reserveCapacity(points.count)
        var run = 0
        var previous: Double?
        for p in points {
            if let previous, p.t - previous > gapMs { run += 1 }
            out.append((run, p))
            previous = p.t
        }
        return out
    }
}
