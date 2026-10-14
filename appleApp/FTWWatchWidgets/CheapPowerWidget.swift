import AppIntents
import FTWShared
import SwiftUI
import WidgetKit

/// A card in the Smart Stack while power is at its cheapest: one for each
/// day's cheapest two hours that stand out, relevant from a quarter hour
/// before until they end. No place clue: that would need location access.
struct CheapPowerWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: WatchKinds.cheap, provider: CheapProvider()) { entry in
            CheapView(entry: entry)
        }
        .configurationDisplayName(WatchWord.cheapWidget.text)
        .description(WatchWord.cheapWidgetSummary.text)
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Which cheap window a card is for. Set by the provider, never by a
/// person.
struct CheapWindowIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Cheap power"
    static let isDiscoverable = false

    @Parameter(title: "Start")
    var startMs: Double?

    @Parameter(title: "End")
    var endMs: Double?

    init() {}

    init(_ w: WatchGlance.CheapWindow) {
        startMs = w.startMs
        endMs = w.endMs
    }
}

struct CheapEntry: RelevanceEntry {
    let window: WatchGlance.CheapWindow?
    /// "Fetched 13:05"
    let fetched: String?
}

struct CheapProvider: RelevanceEntriesProvider {
    /// Shown a little before the window opens, so it is there when it does.
    static let leadMs: Double = 15 * 60_000

    func relevance() async -> WidgetRelevance<CheapWindowIntent> {
        let prices = Kept.read().prices
        let windows = WatchGlance.cheapWindows(prices?.value, nowMs: Date.now.timeIntervalSince1970 * 1000)
        log.info("cheap power: \(windows.count, privacy: .public) windows")
        return WidgetRelevance(windows.map { w in
            WidgetRelevanceAttribute(
                configuration: CheapWindowIntent(w),
                context: .date(interval: DateInterval(start: Date(timeIntervalSince1970: (w.startMs - Self.leadMs) / 1000), end: Date(timeIntervalSince1970: w.endMs / 1000)), kind: .default)
            )
        })
    }

    func entry(configuration: CheapWindowIntent, context: Context) async throws -> CheapEntry {
        let prices = Kept.read().prices
        let nowMs = Date.now.timeIntervalSince1970 * 1000
        let window = WatchGlance.cheapWindows(prices?.value, nowMs: nowMs).first { $0.startMs == configuration.startMs }
        let fetched = prices.map { PriceGlance.moment($0, atMs: nowMs).fetchedText }
        return CheapEntry(window: window, fetched: fetched ?? nil)
    }

    func placeholder(context: Context) -> CheapEntry {
        CheapEntry(window: nil, fetched: nil)
    }
}

struct CheapView: View {
    let entry: CheapEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(WatchWord.cheapNow.text)
                .font(.headline)
                .widgetAccentable()
            if let w = entry.window {
                Text("\(w.range) · \(w.price)")
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(entry.fetched?.uppercased() ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Theme.ground }
        .redacted(reason: entry.window == nil ? .placeholder : [])
    }
}
