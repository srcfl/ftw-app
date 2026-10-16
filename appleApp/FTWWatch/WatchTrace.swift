import FTWShared
import Observation
import SwiftUI

/// Now's live trace on the wrist: the phone's node view trace (`LiveSeries`,
/// drawn in `TraceInk`), for one node at a time. It opens whole: the phone
/// sends its last three minutes with the reply to a look, and the watch
/// keeps them for its next open. A reading counts as seen only when its
/// frame came live, so the line glows only then and is ink otherwise.
///
/// While live the window ends now and scrolls. Otherwise it ends at the
/// newest reading and holds still, so a cached open shows the three
/// minutes it last knew, dated by the status line.
///
/// Built once per frame or change of node or size; the view only scrolls
/// and strokes it.
@Observable
@MainActor
final class WatchTrace {
    /// Three minutes: about one point of width per second on a watch.
    static let windowMs: Double = WatchRecent.windowMs
    /// A reading from the phone this close to one the watch already has is
    /// the same reading, stamped on its way.
    static let sameMs: Double = 900

    private(set) var frame: TraceFrame?
    /// The node the trace follows.
    private(set) var node: WatchNow.Node
    /// Whether the newest frame came live: the window then follows the
    /// clock.
    private(set) var live = false

    @ObservationIgnored private var samples: [WatchNow.Node: [LiveSample]] = [:]
    @ObservationIgnored private var size: CGSize = .zero

    init(node: WatchNow.Node) {
        self.node = node
    }

    /// One frame from the phone. `lit` says whether it came live just now.
    /// A frame the trace already has, an older one, or one that only
    /// repeats a value within a second adds nothing (`LiveSample.adds`), and
    /// the trace is built again only when a point came or the glow changed.
    func add(_ record: CacheRecord<WatchNow>, lit: Bool) {
        var added = false
        for r in record.value.readings {
            guard let v = r.signedW else { continue }
            var run = samples[r.node, default: []]
            let sample = LiveSample(t: record.readAtMs, v: v, seen: lit && r.live)
            guard LiveSample.adds(sample, after: run.last) else { continue }
            run.append(sample)
            samples[r.node] = Self.cut(run, to: record.readAtMs)
            added = true
        }
        guard added || live != lit else { return }
        live = lit
        rebuild(keepScale: true)
    }

    /// The last minutes the phone recorded, or this watch kept, in ink. A
    /// reading the trace already has keeps its place, so what this watch saw
    /// live stays seen.
    func backfill(_ recent: WatchRecent) {
        for lane in recent.lanes {
            let own = samples[lane.node] ?? []
            let times = own.map(\.t)
            let fill = lane.samples.filter { s in
                guard let i = SlotGrid.nearest(times, to: s.t) else { return true }
                return abs(times[i] - s.t) > Self.sameMs
            }
            guard !fill.isEmpty else { continue }
            let run = (own + fill).sorted { $0.t < $1.t }
            samples[lane.node] = Self.cut(run, to: run.last?.t ?? 0)
        }
        rebuild(keepScale: false)
    }

    /// The live frames have stopped: the window holds at the newest reading.
    func settle() {
        guard live else { return }
        live = false
        rebuild(keepScale: true)
    }

    /// The phone signed out: nothing of that home stays.
    func clear() {
        samples = [:]
        live = false
        frame = nil
    }

    /// The last minutes of every node, for the watch's own cache.
    func recent() -> WatchRecent? {
        guard let newest = newestMs else { return nil }
        return WatchRecent.make(samples, nowMs: newest)
    }

    func follow(_ node: WatchNow.Node) {
        guard node != self.node else { return }
        self.node = node
        rebuild(keepScale: false)
    }

    func resize(_ size: CGSize) {
        guard size != self.size, size.width > 0, size.height > 0 else { return }
        self.size = size
        rebuild(keepScale: false)
    }

    private var newestMs: Double? { samples.values.compactMap { $0.last?.t }.max() }

    /// Keep the window and the reading before it, so the line runs off the
    /// left edge.
    private static func cut(_ run: [LiveSample], to endMs: Double) -> [LiveSample] {
        guard let first = run.firstIndex(where: { $0.t >= endMs - windowMs }), first > 1 else { return run }
        return Array(run[(first - 1)...])
    }

    private func rebuild(keepScale: Bool) {
        guard size.width > 0 else { return }
        let now = Date()
        let end = live ? now.timeIntervalSince1970 * 1000 : (newestMs ?? now.timeIntervalSince1970 * 1000)
        let series = LiveSeries.build(
            samples[node] ?? [],
            sourceGapMs: WatchGlance.liveForMs,
            windowMs: Self.windowMs,
            nowMs: end,
            size: size,
            previous: keepScale ? frame?.series.domain : nil,
            floor: node.floorW
        )
        frame = keepScale ? TraceFrame(series: series, after: frame, arrivedAt: now) : TraceFrame(series: series, previous: nil, arrivedAt: now)
    }

    /// Each node's colours, as on the phone: one hue each side of zero; the
    /// battery stores in cyan and gives in gold; the home is ink.
    static func look(_ node: WatchNow.Node) -> TraceLook {
        switch node {
        case .solar: return TraceLook(up: Theme.solar, down: Theme.solar)
        case .battery: return TraceLook(up: Theme.stores, down: Theme.gives)
        case .home: return TraceLook(up: Theme.ink, down: Theme.ink)
        case .grid: return TraceLook(up: Theme.grid, down: Theme.grid)
        case .car: return TraceLook(up: Theme.car, down: Theme.car)
        }
    }
}
