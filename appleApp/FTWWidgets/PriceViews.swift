import Charts
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
        default: return AnyShapeStyle(moment.isEmpty ? Tone.empty : Tone.surface)
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: MediumPrice(moment: moment)
        case .accessoryRectangular: RectangularPrice(moment: moment)
        case .accessoryInline: Label(moment.inlineText, systemImage: Header.symbol)
        default: SmallPrice(moment: moment)
        }
    }
}

/// The home screen's small widget, and StandBy's.
struct SmallPrice: View {
    let moment: PriceGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let price = moment.priceText {
                Header(text: PriceGlance.priceNow)
                PriceFigure(price: price, size: 38)
                Text(moment.unitText).font(.caption2).foregroundStyle(.secondary)
                Text(moment.includedText).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Cheapest(moment: moment)
                Fetched(moment: moment)
            } else {
                Empty(moment: moment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The figures on the left and the next twelve hours on the right.
struct MediumPrice: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let price = moment.priceText {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Header(text: PriceGlance.priceNow)
                    PriceFigure(price: price, size: 34)
                    Text(moment.unitText).font(.caption2).foregroundStyle(.secondary)
                    Text(moment.includedText).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Cheapest(moment: moment)
                    Fetched(moment: moment)
                }
                .frame(width: 128, alignment: .leading)
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

/// The lock screen's rectangle: price, cheapest, what the price holds.
struct RectangularPrice: View {
    let moment: PriceGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let price = moment.priceText {
                Text("\(Image(systemName: Header.symbol)) \(Text(price).font(.headline.monospacedDigit())) \(Text(moment.unitText).font(.caption))")
                    .contentTransition(.numericText())
                    .widgetAccentable()
                if let cheapest = moment.cheapestText {
                    Text(cheapest).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                }
                Text(moment.includedText).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(moment.emptyText ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Parts

/// "⚡ Pris nu": the symbol takes the accent colour, the words stay quiet.
struct Header: View {
    static let symbol = "bolt.fill"
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol)
                .imageScale(.small)
                .foregroundStyle(Tone.accent)
                .widgetAccentable()
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct PriceFigure: View {
    let price: String
    let size: CGFloat

    var body: some View {
        Text(price)
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .widgetAccentable()
    }
}

struct Cheapest: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let text = moment.cheapestText {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.cheap)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()
        }
    }
}

/// When the app fetched these prices. A widget only ever shows the cache.
struct Fetched: View {
    let moment: PriceGlance.Moment

    var body: some View {
        if let text = moment.fetchedText {
            Text(text).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

/// No price for this moment: say why and send the reader to the app.
struct Empty: View {
    let moment: PriceGlance.Moment

    var body: some View {
        Header(text: PriceGlance.title)
        Spacer(minLength: 4)
        Text(moment.emptyText ?? "")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Fetched(moment: moment)
    }
}

/// The next twelve hours as the app draws them (`PriceLineChart`, shared
/// with the app): one stepped line coloured by level, now as a rule and a
/// dot, the cheapest hours as a soft band, the average as a faint rule.
///
/// Tinted and clear home screens and StandBy at night draw in one colour,
/// so there the line is one colour and the band carries the cheap hours.
struct Curve: View {
    let moment: PriceGlance.Moment
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PriceLineChart(
            points: moment.curve.map { PricePoint(startMs: $0.startMs, endMs: $0.endMs, value: PriceUnits.display($0.minor, moment.currency)) },
            nowMs: moment.atMs,
            mean: moment.meanMinor.map { PriceUnits.display($0, moment.currency) },
            cheapest: moment.cheapest.map { $0.startMs...$0.endMs },
            cheapestLabel: nil,
            meanLabel: nil,
            palette: Tone.palette(colorScheme),
            zone: moment.timeZone,
            labelEveryHours: 3,
            monochrome: renderingMode != .fullColor
        )
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}

/// The app's colour roles (FTW/UI/Theme.swift, from the web app's tokens),
/// the few a price widget needs.
enum Tone {
    static let surface = Pair(0xFAFAF8, 0x161616)
    static let empty = Pair(0xDCDCD6, 0x2A2A2A)
    static let cheap = Pair(0x009639, 0x5FD37F)
    static let dear = Pair(0xCC243D, 0xFF6E74)
    static let negative = Pair(0xD48500, 0xFFB000)
    static let flat = Pair(0x686862, 0x858585)
    /// Text and glyphs: the app's darker accent in light, so it reads on
    /// the widget's surface.
    static let accent = Pair(0x9C5800, 0xFFAC41)
    /// Fills and lines: the brand orange.
    static let accentFill = Pair(0xDA7F00, 0xFFAC41)

    /// The price chart's colours, for the scheme the widget draws in.
    static func palette(_ scheme: ColorScheme) -> PriceChartPalette {
        func pick(_ p: Pair) -> Color { scheme == .dark ? p.dark : p.light }
        return PriceChartPalette(cheap: pick(cheap), flat: pick(flat), dear: pick(dear), now: pick(accentFill), quiet: pick(flat), labelBackground: pick(surface))
    }

    static func of(_ tone: PriceStrip.Tone) -> Pair {
        switch tone {
        case .cheap: return cheap
        case .dear: return dear
        case .flat: return flat
        case .negative: return negative
        }
    }
}

/// One colour for light and one for dark, picked by SwiftUI where it draws.
struct Pair: ShapeStyle {
    let light: Color
    let dark: Color

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = Self.color(light)
        self.dark = Self.color(dark)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
