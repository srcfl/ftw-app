#if DEBUG
import os
import QuartzCore
import SwiftUI

/// A debug-only measure of late frames, for where Instruments' Animation
/// Hitches cannot run (the simulator says it is not supported there).
/// With `-FTWFrameLog YES` it wakes at the display's rate
/// and logs, once a second, how many milliseconds the frames came late:
/// each gap longer than 1.5 frames counts for its time past one frame. It
/// sees the main thread's frames, not the render server's.
struct FrameGapProbe: View {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "FTWFrameLog") }

    var body: some View {
        TimelineView(.animation) { context in
            Color.clear.onChange(of: context.date) { FrameGaps.shared.frame(CACurrentMediaTime()) }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class FrameGaps {
    static let shared = FrameGaps()
    private static let log = Logger(subsystem: "energy.ftw.app", category: "frames")
    private var last: CFTimeInterval?
    private var windowStart: CFTimeInterval?
    private var gaps: [Double] = []

    func frame(_ t: CFTimeInterval) {
        defer { last = t }
        guard let last else {
            windowStart = t
            return
        }
        gaps.append(t - last)
        guard let start = windowStart, t - start >= 1 else { return }
        // The median gap is the display's own frame; a gap past 1.5 of
        // them counts for the time beyond one frame.
        let frame = gaps.sorted()[gaps.count / 2]
        let late = gaps.filter { $0 > frame * 1.5 }.reduce(0) { $0 + ($1 - frame) } * 1000
        let seconds = t - start
        let draws = ChartDraws.take()
        Self.log.info("frames \(self.gaps.count) in \(seconds, format: .fixed(precision: 2)) s, late \(late / seconds, format: .fixed(precision: 2)) ms/s, worst gap \((self.gaps.max() ?? 0) * 1000, format: .fixed(precision: 1)) ms, frame \(frame * 1000, format: .fixed(precision: 1)) ms, surface draws \(draws.surface), slot changes \(draws.changes), overlay draws \(draws.overlay), overlay draw \(draws.overlayMs, format: .fixed(precision: 2)) ms, worst \(draws.worstMs, format: .fixed(precision: 2)) ms, trace frames \(draws.traces), trace draw \(draws.traceMs, format: .fixed(precision: 2)) ms, worst \(draws.traceWorstMs, format: .fixed(precision: 2)) ms")
        windowStart = t
        gaps.removeAll(keepingCapacity: true)
    }
}
#endif
