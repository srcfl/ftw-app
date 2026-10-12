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
        case .accessoryInline: Text(moment.inlineText)
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
                Text(PriceGlance.priceNow).font(.caption).foregroundStyle(.secondary)
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
                    Text(PriceGlance.priceNow).font(.caption).foregroundStyle(.secondary)
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
                Text("\(Text(price).font(.headline.monospacedDigit())) \(Text(moment.unitText).font(.caption))")
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
        Text(PriceGlance.title).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Text(moment.emptyText ?? "")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Fetched(moment: moment)
    }
}

/// The next twelve hours as bars from zero, at the resolution the box sent:
/// green below the average ahead, red above, the current slot solid.
struct Curve: View {
    let moment: PriceGlance.Moment

    var body: some View {
        Chart {
            ForEach(moment.curve) { bar in
                mark(bar)
            }
            if let mean = moment.meanMinor {
                RuleMark(y: .value("Average", PriceUnits.display(mean, moment.currency)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Tone.flat)
            }
        }
        .chartXScale(domain: date(start)...date(end))
        .chartXAxis {
            AxisMarks(values: hours) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(Self.hour(d)) }
                }
            }
        }
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }

    /// A bar from zero, as wide as the slot. A rectangle, because a bar
    /// mark with an x interval and one y lies on its side.
    private func mark(_ bar: PriceStrip.Bar) -> some ChartContent {
        let price: Double = PriceUnits.display(bar.minor, moment.currency)
        return RectangleMark(
            xStart: .value("From", date(bar.startMs)),
            xEnd: .value("To", date(bar.endMs)),
            yStart: .value("Zero", 0.0),
            yEnd: .value("Price", price)
        )
        .foregroundStyle(Tone.of(bar.tone))
        .opacity(bar.current ? 1 : 0.55)
    }

    private var start: Double { moment.curve.first?.startMs ?? moment.atMs }
    private var end: Double { moment.curve.last?.endMs ?? moment.atMs }

    /// Every third whole hour, kept clear of the right edge so no label is
    /// cut short.
    private var hours: [Date] {
        let hour: Double = 3_600_000
        var t = (start / hour).rounded(.up) * hour
        var out: [Date] = []
        while t < end - hour {
            if Calendar.current.component(.hour, from: date(t)) % 3 == 0 { out.append(date(t)) }
            t += hour
        }
        return out
    }

    /// "02", on the 24-hour clock the rest of the widget uses.
    private static func hour(_ d: Date) -> String {
        String(format: "%02d", Calendar.current.component(.hour, from: d))
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
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
