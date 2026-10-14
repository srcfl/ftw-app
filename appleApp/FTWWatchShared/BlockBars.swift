import FTWShared
import SwiftUI
import WidgetKit

/// The hours ahead as the block-glyph scale (▁▂▃▄▅▆▇█): one bar per slot,
/// its height the price in eight levels. Ink, stronger for the slot that
/// holds now; never red and green, because a price is a level, not a
/// state. Two still paths, so a complication draws it as cheaply as the
/// app.
struct BlockBars: View {
    let bars: [PriceStrip.Bar]
    /// A stretch to stand out, by time: its bars in full ink and the rest
    /// faint. Without one, the slot that holds now does.
    var highlight: ClosedRange<Double>? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                path(geo.size, strong: false).fill(Theme.ink.opacity(highlight == nil ? 0.55 : 0.3))
                path(geo.size, strong: true).fill(Theme.ink)
                    .widgetAccentable()
            }
        }
    }

    private func strong(_ b: PriceStrip.Bar) -> Bool {
        guard let highlight else { return b.current }
        return b.startMs < highlight.upperBound && b.endMs > highlight.lowerBound
    }

    private func path(_ size: CGSize, strong wanted: Bool) -> Path {
        let values = bars.map(\.minor)
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let gap: CGFloat = bars.count > 30 ? 0.5 : 1
        let w = (size.width - gap * CGFloat(max(bars.count - 1, 0))) / CGFloat(max(bars.count, 1))
        let step = size.height / CGFloat(PlanDial.levels)
        var p = Path()
        for (i, b) in bars.enumerated() where strong(b) == wanted {
            let level = hi - lo < 0.5 ? PlanDial.levels / 2 - 1 : min(PlanDial.levels - 1, Int((b.minor - lo) / (hi - lo) * Double(PlanDial.levels)))
            let h = step * CGFloat(level + 1)
            p.addRect(CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: max(0.6, w), height: h))
        }
        return p
    }
}
