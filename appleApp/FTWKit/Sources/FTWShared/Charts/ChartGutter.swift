import CoreGraphics
import Foundation

/// The right gutter and the corner words of a chart, worked out from the
/// labels it draws. Every glyph of SF Mono has one advance, so a label's
/// width is its length times that, and the plot never reflows to fit one.
public enum ChartGutter {
    /// SF Mono's advance as a share of its size, at every weight: 6.18 pt
    /// at 10 pt.
    public static let monoAdvance: CGFloat = 0.62
    /// Between the plot's right edge and a label.
    public static let gap: CGFloat = 4
    /// After the label, so its last glyph is never cut.
    public static let end: CGFloat = 2

    /// A label in SF Mono at `size`.
    public static func width(_ text: String, size: CGFloat) -> CGFloat {
        CGFloat(text.count) * monoAdvance * size
    }

    /// The gutter that holds the widest of `labels`.
    public static func trailing(_ labels: [String], size: CGFloat) -> CGFloat {
        gap + (labels.map { width($0, size: size) }.max() ?? 0) + end
    }

    /// The labels a power scale draws at its ends: "20 kW", never "0 W".
    public static func scaleLabels(_ domain: YDomain) -> [String] {
        [domain.upper, domain.lower].filter { $0 != 0 }.map { PowerFormat.scale(abs($0)) }
    }
}

/// One x of a chart's data, with the lowest and highest value it reaches
/// there, so a corner word can tell whether the data runs under it.
public struct ChartReach: Equatable, Sendable {
    public var x: CGFloat
    public var low: Double
    public var high: Double

    public init(x: CGFloat, low: Double, high: Double) {
        self.x = x
        self.low = low
        self.high = high
    }
}

/// The direction words (`↑ STORING` top left, `↓ GIVING POWER` bottom
/// left) are drawn only where no data runs: a line through a word reads as
/// neither.
public enum CornerWords {
    /// The word's inset from the plot's corner.
    public static let inset: CGFloat = 2

    /// Whether `word`, in SF Mono at `size`, has its corner to itself: no
    /// point of `data` under it reaches into its band. `top` is the up
    /// word's corner. The first point past the word counts too, since the
    /// line runs to it from under the word.
    public static func clear(_ word: String, size: CGFloat, top: Bool, data: [ChartReach], map: YMap) -> Bool {
        let right = inset + ChartGutter.width(word, size: size) + ChartGutter.gap
        let band = inset + size * 1.3 + 2
        var passed = false
        for p in data.sorted(by: { $0.x < $1.x }) {
            if p.x > right {
                if passed { break }
                passed = true
            }
            if top ? map.y(p.high) <= band : map.y(p.low) >= map.height - band { return false }
        }
        return true
    }
}
