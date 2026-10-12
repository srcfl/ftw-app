import Charts
import FTWKit
import SwiftUI

/// The hours ahead as bars from zero, the hour running now marked, and the
/// average ahead as a dotted line. Small enough to sit beside the price on
/// Now; VoiceOver and Audio Graph read each hour's price.
struct PriceBars: View, Equatable {
    let bars: [PriceStrip.Bar]
    let currency: String
    let mean: Double?

    var body: some View {
        let unit = PriceUnits.unit(currency)
        Chart {
            ForEach(bars) { bar in
                RectangleMark(
                    xStart: .value("From", Date(timeIntervalSince1970: bar.startMs / 1000)),
                    xEnd: .value("To", Date(timeIntervalSince1970: bar.endMs / 1000)),
                    yStart: .value("Zero", 0),
                    yEnd: .value("Price", PriceUnits.display(bar.minor, currency))
                )
                .foregroundStyle(Self.color(bar.tone))
                .opacity(bar.current ? 1 : 0.55)
                .cornerRadius(1.5)
                .accessibilityLabel("\(AppWords.clock(bar.startMs, zone: .current))–\(AppWords.clock(bar.endMs, zone: .current))")
                .accessibilityValue("\(AppWords.decimal(PriceStrip.text(bar.minor, currency))) \(unit.perKwh)")
            }
            if let mean {
                RuleMark(y: .value("Average", PriceUnits.display(mean, currency)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel(L("Prices ahead"))
    }

    static func color(_ tone: PriceStrip.Tone) -> Color {
        switch tone {
        case .dear: return Theme.importing
        case .cheap: return Theme.exporting
        case .flat: return Theme.fgMuted
        case .negative: return Theme.generation
        }
    }
}
