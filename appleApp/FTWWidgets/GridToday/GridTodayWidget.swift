import FTWShared
import os
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "energy.ftw.app", category: "widgets")

/// Today over the grid: net energy with its direction and both sides of
/// it, today's cost as the box priced it, and the day as a chart. Like the
/// other widgets it reads only what the app left in the App Group, and says
/// what time its figures are from.
struct GridTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "energy.ftw.grid-today", provider: GridTodayTimeline()) { entry in
            GridTodayView(moment: entry.moment)
        }
        .configurationDisplayName(GridGlance.title())
        .description(GridGlance.summary())
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular])
    }
}

struct GridTodayTimelineEntry: TimelineEntry {
    let date: Date
    let moment: GridGlance.Moment
}

struct GridTodayTimeline: TimelineProvider {
    func placeholder(in context: Context) -> GridTodayTimelineEntry {
        // Drawn redacted while the real entry loads, so only the shape shows.
        let now = Date.now.timeIntervalSince1970 * 1000
        return GridTodayTimelineEntry(date: .now, moment: GridGlance.moment(Self.sample(nowMs: now), atMs: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (GridTodayTimelineEntry) -> Void) {
        // The gallery shows the shape of a day, not "open FTW".
        let real = entries(now: .now)[0]
        if real.moment.state == .nothing, context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(real)
        }
    }

    /// The app reloads every timeline after it writes. The last entry is
    /// local midnight, where today's figures become yesterday's.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GridTodayTimelineEntry>) -> Void) {
        let entries = entries(now: .now)
        if let last = entries.last?.moment {
            log.info("grid timeline: \(entries.count, privacy: .public) entries, last \(String(describing: last.state), privacy: .public)")
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entries(now: Date) -> [GridTodayTimelineEntry] {
        let reader = CacheReader.shared()
        let read = reader.flatMap { r in r.latestSiteID(GridTodayEntry.self).flatMap { r.read(GridTodayEntry.self, siteId: $0) } }
        if reader == nil { log.error("grid widget: no App Group, nothing to read") }
        return GridGlance.moments(read, nowMs: now.timeIntervalSince1970 * 1000)
            .map { GridTodayTimelineEntry(date: Date(timeIntervalSince1970: $0.atMs / 1000), moment: $0) }
    }

    /// A day's shape for the gallery and the redacted placeholder: a night
    /// that buys, a noon that sells. Never shown as the home's.
    static func sample(nowMs: Double) -> CacheRead<GridTodayEntry> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000)).timeIntervalSince1970 * 1000
        let quarter = GridTodayEntry.quarterMs
        let quarters = (0..<68).map { i -> GridTodayEntry.Quarter in
            let h = Double(i) / 4
            let sun = max(0, sin(Double.pi * (h - 7) / 11))
            let use: Double = 450 + (h >= 6.5 && h < 8.5 ? 1_400 : 0) + (h >= 16 ? 1_900 : 0)
            let net = use - 4_200 * sun
            return GridTodayEntry.Quarter(startMs: start + Double(i) * quarter, importW: max(0, net), exportW: max(0, -net))
        }
        let entry = GridTodayEntry(day: GridTodayEntry.dayName(nowMs, calendar: calendar), dayStartMs: start, dayEndMs: start + 86_400_000,
                                   importWh: 9_400, exportWh: 11_200, costMinor: -360, pricedCoverage: 1, currency: "SEK", timeZone: nil, quarters: quarters)
        let record = CacheRecord(siteId: "", carrier: .none, srcState: .never, readAtMs: start + 68 * quarter, value: entry)
        return CacheRead(record: record, origin: .app)
    }
}
