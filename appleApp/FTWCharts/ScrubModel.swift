import FTWShared
import Observation
import os

/// The finger on one chart. The overlay that draws the marker and the hero
/// that reads the value are the only views that read it, so a touch
/// redraws those two and nothing else. The slot is a clamped index that
/// never animates; the haptic counters move in the same update as it.
/// Two fingers hold a span of slots instead.
@Observable
@MainActor
final class ScrubModel {
    /// The slot under one finger; nil when no finger is down or two are.
    private(set) var index: Int?
    /// The slots between two fingers, both ends included.
    private(set) var span: ClosedRange<Int>?
    /// What was last touched, kept so the marker fades out where it was.
    private(set) var shown: Shown?
    /// Bumped per `.selection` and per light impact.
    private(set) var ticks = 0
    private(set) var bumps = 0

    enum Shown: Equatable {
        case slot(Int)
        case span(ClosedRange<Int>)
    }

    var isDown: Bool { index != nil || span != nil }

    @ObservationIgnored private var step = ScrubStep()
    @ObservationIgnored private var spanStep = ScrubStep()

    static let log = Logger(subsystem: "energy.ftw.app", category: "scrub")

    /// One finger is over slot `next`. Work happens only on a new slot.
    func move(to next: Int, landmark: Bool) {
        guard next != index || span != nil else { return }
        if span != nil {
            span = nil
            spanStep.lift()
        }
        step.move(to: next, landmark: landmark)
        index = next
        show(.slot(next))
        Self.log.debug("touching index \(next) ticks \(self.ticks) bumps \(self.bumps)")
    }

    /// Two fingers hold slots `a` and `b`. A span that forms gives a light
    /// impact, as its ends do; a moved end ticks.
    func spread(_ a: Int, _ b: Int) {
        let next = min(a, b)...max(a, b)
        guard next != span else { return }
        let forming = span == nil
        if index != nil {
            index = nil
            step.lift()
        }
        // One number per span, so the step's floor and crossing rules hold.
        spanStep.move(to: next.lowerBound &* 65_536 &+ next.upperBound, landmark: forming)
        span = next
        show(.span(next))
        Self.log.debug("touching span \(next.lowerBound)–\(next.upperBound) ticks \(self.ticks) bumps \(self.bumps)")
    }

    /// Every finger lifted, or the gesture ended.
    func lift() {
        guard isDown else { return }
        step.lift()
        spanStep.lift()
        index = nil
        span = nil
        Self.log.debug("lifted")
    }

    private func show(_ next: Shown) {
        #if DEBUG
        ChartDraws.changes += 1
        #endif
        if shown != next { shown = next }
        let t = step.ticks + spanStep.ticks, b = step.bumps + spanStep.bumps
        if ticks != t { ticks = t }
        if bumps != b { bumps = b }
    }
}
