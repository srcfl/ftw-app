import FTWShared
import SwiftUI

/// The price on one screen: the price now, the hours ahead as block bars in
/// eight levels, when it is cheapest, and when the prices were fetched.
/// Prices are a level, never a state: ink, stronger as they get dearer,
/// with no red and no green.
struct PricePage: View {
    let model: WatchModel

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let m = PriceGlance.moment(model.context?.prices.map { CacheRead(record: $0, origin: .app) }, atMs: nowMs)
            OnePage {
                VStack(alignment: .leading, spacing: 3) {
                    if let price = m.priceText {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(price)
                                .font(Theme.figure(34))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(m.unitText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                        Text(m.includedText)
                            .font(.caption2)
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(m.emptyText ?? "—")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(2)
                    }
                    BlockBars(bars: m.curve)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 3)
                        .accessibilityHidden(true)
                    if let cheap = m.cheapestText {
                        Text(cheap)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let fetched = m.fetchedText {
                        Text(fetched.uppercased())
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("watch.price")
        }
        .navigationTitle(WatchWord.priceTitle.text)
    }
}
