import FTWShared
import SwiftUI

/// The price now, the next twelve hours as block bars in eight levels, and
/// when it is cheapest. Prices are a level, never a state: ink, stronger as
/// they get dearer, with no red and no green.
struct PricePage: View {
    let model: WatchModel

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let m = PriceGlance.moment(model.context?.prices.map { CacheRead(record: $0, origin: .app) }, atMs: nowMs)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text(WatchWord.priceNow.text.uppercased())
                        .font(Theme.mono(.caption2))
                        .foregroundStyle(Theme.ink3)
                    if let price = m.priceText {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(price)
                                .font(Theme.figure(34))
                                .foregroundStyle(Theme.ink)
                            Text(m.unitText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.ink2)
                        }
                        Text(m.includedText)
                            .font(.caption2)
                            .foregroundStyle(Theme.ink3)
                    } else {
                        Text(m.emptyText ?? "—")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                    }
                    if !m.curve.isEmpty {
                        BlockBars(bars: m.curve)
                            .frame(height: 30)
                            .padding(.vertical, 2)
                            .accessibilityHidden(true)
                    }
                    if let cheap = m.cheapestText {
                        Text(cheap)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    if let fetched = m.fetchedText {
                        Text(fetched.uppercased())
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("watch.price")
        }
        .navigationTitle(WatchWord.priceTitle.text)
    }
}
