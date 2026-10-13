import FTWShared
import os
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "energy.ftw.app", category: "widgets")

/// What FTW plans to do next and over the next hours, from the plan the app
/// left in the App Group. Like the price widget it opens no connection: an
/// hour after the plan was made it goes grey and says how old it is.
struct PlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "energy.ftw.plan", provider: PlanTimeline()) { entry in
            PlanWidgetView(moment: entry.moment)
        }
        .configurationDisplayName(PlanGlance.title)
        .description(PlanGlance.summaryText)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct PlanWidgetEntry: TimelineEntry {
    let date: Date
    let moment: PlanGlance.Moment
}

struct PlanTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PlanWidgetEntry {
        let now = Date.now.timeIntervalSince1970 * 1000
        return PlanWidgetEntry(date: .now, moment: PlanGlance.moment(Self.sample(nowMs: now), atMs: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanWidgetEntry) -> Void) {
        // The gallery shows the shape of a plan, not "open FTW".
        let real = entries(now: .now)[0]
        if real.moment.state == .nothing, context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(real)
        }
    }

    /// The app reloads every timeline after it writes. The entries run to
    /// the end of the plan's horizon and the moment it turns old.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanWidgetEntry>) -> Void) {
        let entries = entries(now: .now)
        if let last = entries.last?.moment {
            log.info("plan timeline: \(entries.count, privacy: .public) entries, last \(String(describing: last.state), privacy: .public)")
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entries(now: Date) -> [PlanWidgetEntry] {
        let reader = CacheReader.shared()
        let read = reader.flatMap { r in r.latestSiteID(PlanEntry.self).flatMap { r.read(PlanEntry.self, siteId: $0) } }
        if reader == nil { log.error("plan widget: no App Group, nothing to read") }
        return PlanGlance.moments(read, nowMs: now.timeIntervalSince1970 * 1000)
            .map { PlanWidgetEntry(date: Date(timeIntervalSince1970: $0.atMs / 1000), moment: $0) }
    }

    /// A night's plan for the gallery and the redacted placeholder. Never
    /// shown as the home's plan.
    static func sample(nowMs: Double) -> CacheRead<PlanEntry> {
        let hour: Double = 3_600_000
        let start = (nowMs / hour).rounded(.down) * hour
        let battery = (0..<48).map { i -> PlanEntry.Slot in
            let w: Double = i >= 4 && i < 10 ? 3_000 : (i >= 30 && i < 38 ? -2_000 : 0)
            return PlanEntry.Slot(startMs: start + Double(i) * hour / 4, durationMs: hour / 4, batteryW: w, reason: "idle")
        }
        let prices = (0..<12).map { i in PriceSlot(startMs: start + Double(i) * hour, durationMs: hour, spotMinor: 40, totalMinor: 60 + Double((i * 37) % 50)) }
        let entry = PlanEntry(
            battery: battery,
            charges: [.init(loadpointID: "car", fromMs: start + 3 * hour, toMs: start + 6 * hour, energyWh: 30_000, targetPct: 80)],
            prices: prices,
            currency: "SEK",
            boxStale: false
        )
        let record = CacheRecord(siteId: "", carrier: .none, srcState: .live, readAtMs: nowMs, value: entry)
        return CacheRead(record: record, origin: .app)
    }
}
