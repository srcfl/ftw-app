import FTWShared
import SwiftUI
import WidgetKit

@main
struct FTWWidgets: WidgetBundle {
    var body: some Widget {
        PriceWidget()
    }
}

/// The price now and the cheapest two hours ahead, from what the app left in
/// the App Group. A widget opens no connection and holds no key.
struct PriceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "energy.ftw.prices", provider: PriceTimeline()) { moment in
            PriceWidgetView(moment: moment)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Electricity price")
        .description("The price now and the cheapest two hours ahead.")
        .supportedFamilies([.systemSmall])
    }
}

struct PriceMoment: TimelineEntry {
    let date: Date
    /// Nil when the app has left nothing: not paired, or signed out.
    let read: CacheRead<PriceEntry>?
}

struct PriceTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PriceMoment {
        PriceMoment(date: .now, read: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceMoment) -> Void) {
        completion(moments(now: .now)[0])
    }

    /// The app reloads every timeline after it writes, so nothing here asks
    /// to be woken.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceMoment>) -> Void) {
        completion(Timeline(entries: moments(now: .now), policy: .never))
    }

    /// One moment now and one at every price boundary ahead. The last falls
    /// where the prices end, so the widget says they ran out rather than
    /// showing the last hour again.
    func moments(now: Date) -> [PriceMoment] {
        guard let reader = CacheReader.shared(),
              let site = reader.latestSiteID(PriceEntry.self),
              let read = reader.read(PriceEntry.self, siteId: site) else {
            return [PriceMoment(date: now, read: nil)]
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        let ahead = Set(read.value.prices.slots.map { $0.startMs + $0.durationMs }.filter { $0 > nowMs }).sorted()
        return [PriceMoment(date: now, read: read)] + ahead.map { PriceMoment(date: Date(timeIntervalSince1970: $0 / 1000), read: read) }
    }
}

struct PriceWidgetView: View {
    let moment: PriceMoment

    var body: some View {
        if let read = moment.read {
            prices(read)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("FTW").font(.headline)
                Text("Open FTW to see prices.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func prices(_ read: CacheRead<PriceEntry>) -> some View {
        let prices = read.value.prices
        let summary = PriceStrip.summary(prices, nowMs: moment.date.timeIntervalSince1970 * 1000)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Price now").font(.caption).foregroundStyle(.secondary)
            if let current = summary.current {
                Text(PriceStrip.text(current.totalMinor, prices.currency))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(PriceUnits.unit(prices.currency).perKwh).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let cheapest = summary.cheapest {
                    Text("Cheapest \(time(cheapest.startMs))–\(time(cheapest.endMs))")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                Spacer(minLength: 2)
                Text(endText(prices)).font(.caption).foregroundStyle(.secondary)
            }
            // Read back from the phone, never live: say when it was fetched.
            Text("Updated \(time(read.record.readAtMs))").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func endText(_ prices: Prices) -> String {
        guard let last = prices.slots.map({ $0.startMs + $0.durationMs }).max() else { return "No prices · open FTW" }
        return "No prices after \(time(last)) · open FTW"
    }

    private func time(_ ms: Double) -> String {
        Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
    }
}
