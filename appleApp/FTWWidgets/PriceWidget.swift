import FTWShared
import os
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "energy.ftw.app", category: "widgets")
private let signposter = OSSignposter(subsystem: "energy.ftw.app", category: "widgets")

@main
struct FTWWidgets: WidgetBundle {
    var body: some Widget {
        PriceWidget()
        PlanWidget()
        PlanDialWidget()
        ChargeNowControl()
        ChargeNowLiveActivity()
    }
}

/// The price now, when it is cheapest next, and a short curve, from what the
/// app left in the App Group. A widget opens no connection and holds no key.
/// Prices are not secret, so the lock screen shows them as they are.
struct PriceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "energy.ftw.prices", provider: PriceTimeline()) { entry in
            PriceWidgetView(moment: entry.moment)
        }
        .configurationDisplayName(PriceGlance.title)
        .description(PriceGlance.summary)
        // systemSmall is also the StandBy widget.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct PriceWidgetEntry: TimelineEntry {
    let date: Date
    let moment: PriceGlance.Moment
}

struct PriceTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PriceWidgetEntry {
        // Drawn redacted while the real entry loads, so only the shape shows.
        let now = Date.now.timeIntervalSince1970 * 1000
        return PriceWidgetEntry(date: .now, moment: PriceGlance.moment(Self.sample(nowMs: now), atMs: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceWidgetEntry) -> Void) {
        completion(entries(now: .now)[0])
    }

    /// The app reloads every timeline after it writes, so nothing here asks
    /// to be woken. The last entry falls where the prices end and stays.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceWidgetEntry>) -> Void) {
        let interval = signposter.beginInterval("price timeline")
        let started = ContinuousClock.now
        let entries = entries(now: .now)
        let ms = (ContinuousClock.now - started) / .milliseconds(1)
        signposter.endInterval("price timeline", interval)
        if let last = entries.last?.moment {
            log.info("price timeline: \(entries.count, privacy: .public) entries in \(ms, format: .fixed(precision: 1), privacy: .public) ms, last \(String(describing: last.state), privacy: .public)")
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entries(now: Date) -> [PriceWidgetEntry] {
        let reader = CacheReader.shared()
        let read = reader.flatMap { r in r.latestSiteID(PriceEntry.self).flatMap { r.read(PriceEntry.self, siteId: $0) } }
        if reader == nil { log.error("price widget: no App Group, nothing to read") }
        return PriceGlance.moments(read, nowMs: now.timeIntervalSince1970 * 1000)
            .map { PriceWidgetEntry(date: Date(timeIntervalSince1970: $0.atMs / 1000), moment: $0) }
    }

    /// A day's shape for the redacted placeholder. Never shown as a price.
    static func sample(nowMs: Double) -> CacheRead<PriceEntry> {
        let hour: Double = 3_600_000
        let start = (nowMs / hour).rounded(.down) * hour
        let slots = (0..<12).map { i in
            PriceSlot(startMs: start + Double(i) * hour, durationMs: hour, spotMinor: 40, totalMinor: 60 + Double((i * 37) % 50))
        }
        let prices = Prices(zone: "", currency: "SEK", slots: slots, stale: false)
        let record = CacheRecord(siteId: "", carrier: .none, srcState: .never, readAtMs: nowMs, value: PriceEntry(fromMs: start, prices: prices))
        return CacheRead(record: record, origin: .app)
    }
}
