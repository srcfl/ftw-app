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
    /// The hours ahead, the window among them.
    let bars: [PriceStrip.Bar]
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
        let bars = prices.map { PriceGlance.moment($0, atMs: nowMs).curve } ?? []
        return CheapEntry(window: window, bars: bars)
    }

    func placeholder(context: Context) -> CheapEntry {
        CheapEntry(window: nil, bars: [])
    }
}

/// The card: a glyph, the window's hours and its price, then the hours
/// ahead with the window standing out. No sentence; the glyph and the
/// bars carry it.
struct CheapView: View {
    let entry: CheapEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .widgetAccentable()
                Text(entry.window?.range ?? "00:00–00:00")
                    .font(.system(.headline).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                Text(entry.window?.short ?? "00")
                    .font(.system(.body).monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }
            BlockBars(bars: entry.bars, highlight: entry.window.map { $0.startMs...$0.endMs })
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Theme.ground }
        .redacted(reason: entry.window == nil ? .placeholder : [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.window.map { "\(WatchWord.cheapNow.text), \($0.range), \($0.price)" } ?? WatchWord.cheapWidget.text)
    }
}
