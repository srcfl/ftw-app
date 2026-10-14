import FTWShared
import SwiftUI
import WidgetKit

/// The dial unrolled: the next hours from now on the left, one bar per
/// quarter, its height the price in eight levels and its colour what the
/// battery does (cyan stores, ink gives, ink3 waits), the car's charging as
/// dots under it. A quarter with no price yet is a stub. Still paths, one
/// fill each, for a complication.
struct PlanStrip: View {
    let dial: WatchDial
    /// How many quarters to draw: 48 is twelve hours.
    var quarters = 48
    var grey = false

    var body: some View {
        GeometryReader { geo in
            let n = min(quarters, dial.quarters.count)
            let dotRow: CGFloat = dial.quarters.prefix(n).contains(where: \.car) ? 3 : 0
            let h = geo.size.height - dotRow - (dotRow > 0 ? 1 : 0)
            let w = geo.size.width / CGFloat(max(n, 1))
            ZStack(alignment: .topLeading) {
                bars(.waits, n: n, w: w, h: h).fill(grey ? Theme.ink3.opacity(0.45) : Theme.ink3.opacity(0.6))
                bars(.gives, n: n, w: w, h: h).fill(grey ? Theme.ink3.opacity(0.45) : Theme.ink)
                bars(.stores, n: n, w: w, h: h).fill(grey ? Theme.ink3.opacity(0.45) : Theme.stores)
                    .widgetAccentable()
                stubs(n: n, w: w, h: h).fill(Theme.ink3.opacity(0.5))
                if dotRow > 0 {
                    carDots(n: n, w: w, y: geo.size.height - dotRow / 2).fill(grey ? Theme.ink3 : Theme.car)
                        .widgetAccentable()
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ action: WatchDial.Battery, n: Int, w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        for i in 0..<n {
            let q = dial.quarters[i]
            guard q.battery == action, let level = q.level else { continue }
            let bh = h * CGFloat(level + 1) / CGFloat(WatchDial.levels)
            p.addRect(CGRect(x: CGFloat(i) * w, y: h - bh, width: max(0.6, w - 0.6), height: bh))
        }
        return p
    }

    private func stubs(n: Int, w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        for i in 0..<n where dial.quarters[i].minor == nil {
            let bh = max(1, h / CGFloat(WatchDial.levels) * 0.6)
            p.addRect(CGRect(x: CGFloat(i) * w, y: h - bh, width: max(0.6, w - 0.6), height: bh))
        }
        return p
    }

    private func carDots(n: Int, w: CGFloat, y: CGFloat) -> Path {
        var p = Path()
        for i in 0..<n where dial.quarters[i].car && i % 2 == 0 {
            let r: CGFloat = 1.1
            p.addEllipse(in: CGRect(x: CGFloat(i) * w + w / 2 - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return p
    }
}

/// What happens next, as a glyph.
enum EventGlyph {
    static func name(_ kind: PlanGlance.Kind?) -> String {
        switch kind {
        case .charge?: return "battery.100percent.bolt"
        case .discharge?: return "battery.50percent"
        case .car?: return "car.fill"
        case .cheap?: return "arrow.down.circle"
        case nil: return "minus"
        }
    }
}
