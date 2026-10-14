import SwiftUI

/// A level in tenths, one of the six TUI details: ten cells with 1.2 pt
/// gaps, as many lit as the level has tenths, readable at 4 pt. Lit cells
/// glow only while live, and only in the dark.
struct CellMeter: View {
    let pct: Double
    let tint: Color
    let live: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let lit = Int((min(max(pct, 0), 100) / 10).rounded())
        Canvas { g, size in
            let gap: CGFloat = 1.2
            let w = (size.width - 9 * gap) / 10
            for i in 0..<10 {
                let cell = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                if i < lit {
                    if live && scheme == .dark && !reduceTransparency {
                        g.fill(Path(roundedRect: cell.insetBy(dx: -1, dy: -1.5), cornerRadius: 1.5), with: .color(tint.opacity(0.25)))
                    }
                    g.fill(Path(roundedRect: cell, cornerRadius: 0.75), with: .color(live ? tint : Theme.ink3))
                } else {
                    g.fill(Path(roundedRect: cell, cornerRadius: 0.75), with: .color(Theme.ink.opacity(0.12)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
