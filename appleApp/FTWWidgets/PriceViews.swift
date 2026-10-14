import FTWShared
import SwiftUI
import WidgetKit

/// One moment of the price widget, in whichever family it sits. Every
/// sentence comes from `PriceGlance`; this file only lays them out.
struct PriceWidgetView: View {
    let moment: PriceGlance.Moment
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { Rectangle().fill(background) }
    }

    /// Grey when there is no price for this moment. The lock screen draws
    /// its own, so the accessory families bring none.
    private var background: AnyShapeStyle {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: return AnyShapeStyle(.clear)
        default: return AnyShapeStyle(moment.isEmpty ? Theme.hairline : Theme.ground)
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: MediumPrice(moment: moment)
        case .accessoryRectangular: RectangularPrice(moment: moment)
        case .accessoryInline: Label(moment.inlineText, systemImage: RectangularPrice.symbol)
        default: SmallPrice(moment: moment)
        }
    }
}

/// The home screen's small widget, and StandBy's: the price now, the next
/// twelve hours as blocks, the cheapest two hours and when it was fetched.
struct SmallPrice: View {
    let moment: PriceGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let price = moment.priceText {
                Kicker(text: PriceGlance.priceNow)
                PriceFigure(price: price, size: 36)
                Units(moment: moment, lines: 1)
                Spacer(minLength: 4)
                BlockStrip(hours: moment.hours)
                    .frame(height: 18)
                    .padding(.bottom, 4)
                Cheapest(moment: moment)
                AsOf(moment: moment)
            } else {
                Empty(moment: moment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The figures on the left and the next twelve hours on the right, as the
/// app's price chart draws them.
struct MediumPrice: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let price = moment.priceText {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker(text: PriceGlance.priceNow)
                    PriceFigure(price: price, size: 34)
                    Units(moment: moment, lines: 2)
                    Spacer(minLength: 4)
                    Cheapest(moment: moment)
                    AsOf(moment: moment)
                }
                .frame(width: 124, alignment: .leading)
                .accessibilityElement(children: .combine)
                Curve(moment: moment)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 2) { Empty(moment: moment) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The lock screen's rectangle, in the terminal layer: the price, the next
/// twelve hours as block glyphs (▁▂▃▄▅▆▇█), one per hour from now, and the
/// cheapest two hours with when it was fetched.
struct RectangularPrice: View {
    static let symbol = "bolt.fill"
    let moment: PriceGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let price = moment.priceText {
                Text("\(Text(price).font(.headline.monospacedDigit())) \(Text(moment.unitText).font(.caption))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                    .widgetAccentable()
                Text(verbatim: moment.glyphs)
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityHidden(true)
                Text([moment.cheapestText, moment.asOfText].compactMap { $0?.uppercased() }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(moment.emptyText ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Parts

/// "42,3": SF Pro with even digits, as every figure in the app.
struct PriceFigure: View {
    let price: String
    let size: CGFloat

    var body: some View {
        Text(price)
            .font(Theme.figure(size))
            .tracking(-0.5)
            .foregroundStyle(Theme.ink)
            .contentTransition(.numericText())
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .widgetAccentable()
    }
}

/// "öre/kWh · incl. grid fee and VAT", in ink2.
struct Units: View {
    let moment: PriceGlance.Moment
    let lines: Int

    var body: some View {
        Text("\(moment.unitText) · \(moment.includedText)")
            .font(.caption2)
            .foregroundStyle(Theme.ink2)
            .lineLimit(lines)
            .minimumScaleFactor(0.75)
    }
}

/// `CHEAPEST 02–04`, in the terminal layer.
struct Cheapest: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let text = moment.cheapestText {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()
        }
    }
}

/// `AS OF 13:05`: when the app fetched these prices. A widget only ever
/// shows the cache, so it always says when, and never glows.
struct AsOf: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let text = moment.asOfText {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// No price for this moment: say why and send the reader to the app.
struct Empty: View {
    let moment: PriceGlance.Moment

    var body: some View {
        Kicker(text: PriceGlance.title)
        Spacer(minLength: 4)
        Text(moment.emptyText ?? "")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        AsOf(moment: moment)
    }
}

/// The next twelve hours as the block-glyph scale in still bars: one per
/// hour, its height one of eight levels, in ink by thirds, the hour that
/// holds now in full ink. Tinted and clear home screens draw them in one
/// colour; the now bar takes the accent.
struct BlockStrip: View {
    let hours: [PriceBlocks.Hour]
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let full = renderingMode == .fullColor
            let ink: Color = full ? Theme.ink : .primary
            let paths = Self.paths(hours, size: geo.size, scale: displayScale)
            ZStack(alignment: .topLeading) {
                paths.cheap.fill(ink.opacity(0.32))
                paths.middle.fill(ink.opacity(0.5))
                paths.dear.fill(ink.opacity(0.8))
                paths.now.fill(ink).widgetAccentable()
            }
        }
        .accessibilityHidden(true)
    }

    /// Twelve slots across the width with a 2 pt gap, each bar's height a
    /// level of eight steps, pixel-snapped.
    static func paths(_ hours: [PriceBlocks.Hour], size: CGSize, scale: CGFloat) -> (cheap: Path, middle: Path, dear: Path, now: Path) {
        let scale = max(scale, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        var cheap = Path(), middle = Path(), dear = Path(), now = Path()
        let slots = CGFloat(PriceGlance.stripHours), gap: CGFloat = 2
        let w = (size.width - gap * (slots - 1)) / slots
        for (i, h) in hours.enumerated() {
            let height = snap(size.height * CGFloat(h.level) / 8)
            let rect = CGRect(x: snap(CGFloat(i) * (w + gap)), y: size.height - height, width: snap(w), height: height)
            let bar = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 1.25, bottomLeading: 0, bottomTrailing: 0, topTrailing: 1.25))
            if h.current {
                now.addPath(bar)
            } else {
                switch h.third {
                case .cheap: cheap.addPath(bar)
                case .middle: middle.addPath(bar)
                case .dear: dear.addPath(bar)
                }
            }
        }
        return (cheap, middle, dear, now)
    }
}

/// The next twelve hours as the app draws them (`PricePaths`, shared with
/// the app): a bar per slot in ink by thirds, the now slot in full ink,
/// the average as a dotted rule and the cheapest two hours bracketed.
///
/// Tinted and clear home screens and StandBy at night draw in one colour;
/// the bars keep their three strengths.
struct Curve: View {
    let moment: PriceGlance.Moment
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        PriceBarsStill(
            chart: PriceChart.build(bars: moment.curve, currency: moment.currency, nowMs: moment.atMs, spanMs: PriceGlance.curveMs, everyHours: 3, clock: ZoneClock.of(moment.timeZone)),
            monochrome: renderingMode != .fullColor
        )
        .accessibilityHidden(true)
    }
}
