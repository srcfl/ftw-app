import FTWKit
import SwiftUI

/// The quarters a change moved, as the old plan drew them, over the new
/// plan: on the ground's colour, masked to those quarters, and faded out in
/// 0.2 s. Only the moved quarters cross-fade; the rest never change. Drawn
/// once, as the new plan arrives; a view opened later shows the new plan
/// at once.
struct MovedFade<Content: View, Mask: Shape>: View {
    let mask: Mask
    let content: Content
    @State private var shown: Bool

    init(fresh: Bool, mask: Mask, @ViewBuilder content: () -> Content) {
        self.mask = mask
        self.content = content()
        _shown = State(initialValue: fresh)
    }

    var body: some View {
        ZStack {
            Theme.ground
            content
        }
        .mask(mask)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard shown else { return }
            withAnimation(.easeOut(duration: 0.2)) { shown = false }
        }
    }
}

/// The strip before a change, and the quarters the change moved.
struct StripFade: Equatable {
    let old: PlanStrip
    let moved: [Int]
    let atMs: Double
    let fresh: Bool

    /// Nil when the change moved nothing the strip draws.
    static func make(_ before: (entry: PlanEntry, atMs: Double, fresh: Bool)?, strip: PlanStrip, nowMs: Double, hasCar: Bool) -> StripFade? {
        guard let before else { return nil }
        let old = PlanStrip.build(before.entry, moment: PlanGlance.live(before.entry, nowMs: nowMs), hasCar: hasCar)
        let moved = strip.moved(from: old)
        return moved.isEmpty ? nil : StripFade(old: old, moved: moved, atMs: before.atMs, fresh: before.fresh)
    }
}

/// The dial before a change, and the quarters the change moved.
struct DialFade: Equatable {
    let old: PlanDial
    let moved: [Int]
    let atMs: Double
    let fresh: Bool

    static func make(_ before: (entry: PlanEntry, atMs: Double, fresh: Bool)?, dial: PlanDial, nowMs: Double) -> DialFade? {
        guard let before else { return nil }
        let old = PlanDial(plan: before.entry, prices: nil, nowMs: nowMs)
        let moved = dial.moved(from: old)
        return moved.isEmpty ? nil : DialFade(old: old, moved: moved, atMs: before.atMs, fresh: before.fresh)
    }
}

/// The strip's columns for some quarters, top to bottom.
struct QuarterColumns: Shape {
    let grid: SlotGrid
    let quarters: [Int]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in quarters {
            let x0 = grid.x(atMs: grid.startMs(i), width: rect.width)
            let x1 = grid.x(atMs: grid.endMs(i), width: rect.width)
            p.addRect(CGRect(x: rect.minX + x0 - 0.5, y: rect.minY, width: x1 - x0 + 1, height: rect.height))
        }
        return p
    }
}

/// The dial's wedges for some quarters, from the middle out past the rim.
struct QuarterWedges: Shape {
    let dial: PlanDial
    let quarters: [Int]

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = max(rect.width, rect.height)
        func at(_ a: Double) -> CGPoint { CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a)) }
        var p = Path()
        for i in quarters {
            let a0 = dial.angle(dial.grid.startMs(i))
            var a1 = dial.angle(dial.grid.endMs(i))
            if a1 < a0 { a1 += 2 * .pi }
            // A hair wider, so two wedges side by side leave no seam.
            p.move(to: c)
            p.addLine(to: at(a0 - 0.004))
            p.addLine(to: at((a0 + a1) / 2))
            p.addLine(to: at(a1 + 0.004))
            p.closeSubpath()
        }
        return p
    }
}
