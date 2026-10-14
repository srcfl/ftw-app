import FTWShared
import Observation
import SwiftUI

/// Now's live trace on the wrist: the phone's node view trace (`LiveSeries`,
/// drawn in `TraceInk`), for one node at a time, from the frames the phone
/// passes on while the watch looks. A reading counts as seen only when its
/// frame came live, so the line glows only then and is ink otherwise.
///
/// Built once per frame or change of node or size; the view only scrolls
/// and strokes it.
@Observable
@MainActor
final class WatchTrace {
    /// Three minutes: about one point of width per second on a watch.
    static let windowMs: Double = 3 * 60_000

    private(set) var frame: TraceFrame?
    /// The node the trace follows.
    private(set) var node: WatchNow.Node

    @ObservationIgnored private var samples: [WatchNow.Node: [LiveSample]] = [:]
    @ObservationIgnored private var size: CGSize = .zero

    init(node: WatchNow.Node) {
        self.node = node
    }

    /// One frame from the phone. `lit` says whether it came live just now.
    func add(_ record: CacheRecord<WatchNow>, lit: Bool) {
        let from = record.readAtMs - Self.windowMs
        for r in record.value.readings {
            guard let v = r.signedW else { continue }
            var run = samples[r.node, default: []]
            // A frame the trace already has, or an older one, adds nothing.
            if let last = run.last, last.t >= record.readAtMs { continue }
            run.append(LiveSample(t: record.readAtMs, v: v, seen: lit && r.live))
            if let cut = run.firstIndex(where: { $0.t >= from }), cut > 1 { run.removeFirst(cut - 1) }
            samples[r.node] = run
        }
        rebuild(keepScale: true)
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

    private func rebuild(keepScale: Bool) {
        guard size.width > 0 else { return }
        let now = Date()
        let series = LiveSeries.build(
            samples[node] ?? [],
            sourceGapMs: WatchGlance.liveForMs,
            windowMs: Self.windowMs,
            nowMs: now.timeIntervalSince1970 * 1000,
            size: size,
            previous: keepScale ? frame?.series.domain : nil,
            floor: node.floorW
        )
        frame = TraceFrame(series: series, previous: keepScale ? frame?.series : nil, arrivedAt: now)
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
