import FTWShared
import SwiftUI
import WidgetKit

/// The plan on the watch face. Circular: the dial, a ring of prices with
/// the battery's action, the hand at now and the battery's level in the
/// middle while it is recent. Rectangular: what happens next, the price
/// strip and when the plan was made. Corner: the price now and when it is
/// cheapest. Inline: the price now.
struct PlanComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchKinds.plan, provider: FaceTimeline()) { entry in
            PlanComplicationView(face: entry.face)
        }
        .configurationDisplayName(WatchWord.planWidget.text)
        .description(WatchWord.planWidgetSummary.text)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct FaceEntry: TimelineEntry {
    let date: Date
    let face: WatchGlance.Face
}

struct FaceTimeline: TimelineProvider {
    func placeholder(in context: Context) -> FaceEntry {
        let now = Date.now.timeIntervalSince1970 * 1000
        return FaceEntry(date: .now, face: WatchGlance.faces(plan: nil, prices: nil, now: nil, nowMs: now)[0])
    }

    func getSnapshot(in context: Context, completion: @escaping (FaceEntry) -> Void) {
        completion(entries(now: .now)[0])
    }

    /// The watch app reloads this whenever the phone hands over new
    /// records. The entries step a quarter hour at a time, so the hand
    /// moves without waking anything.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceEntry>) -> Void) {
        let entries = entries(now: .now)
        log.info("plan complication: \(entries.count, privacy: .public) entries")
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entries(now: Date) -> [FaceEntry] {
        let kept = Kept.read()
        return WatchGlance.faces(plan: kept.plan, prices: kept.prices, now: kept.now, nowMs: now.timeIntervalSince1970 * 1000)
            .map { FaceEntry(date: Date(timeIntervalSince1970: $0.atMs / 1000), face: $0) }
    }
}

struct PlanComplicationView: View {
    let face: WatchGlance.Face
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryCorner: corner
        default: inline
        }
    }

    private var circular: some View {
        ZStack {
            if let dial = face.dial {
                PlanDialView(dial: dial, grey: face.plan.isGrey, size: .small)
            } else {
                Circle().stroke(Theme.ink3, lineWidth: 1)
            }
            Text(face.batteryPct.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .widgetAccentable()
        }
        .containerBackground(for: .widget) { Theme.ground }
        .accessibilityLabel(face.plan.summary)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(face.plan.nextWhat.map { [face.plan.nextWhen, $0].compactMap { $0 }.joined(separator: " · ") } ?? face.plan.summary)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .widgetAccentable()
            Text(face.plan.nextUntil ?? face.plan.cheapText ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !face.price.curve.isEmpty {
                BlockBars(bars: face.price.curve)
                    .frame(height: 10)
            }
            Text(planAge)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(for: .widget) { Theme.ground }
    }

    private var corner: some View {
        Text(face.price.priceText ?? "–")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .widgetCurvesContent()
            .widgetLabel {
                Text(face.price.priceText == nil ? (face.price.emptyText ?? "") : (face.price.cheapestStartText ?? face.price.unitLabel))
            }
            .containerBackground(for: .widget) { Theme.ground }
    }

    /// The inline slot is as narrow as a date on some faces and the system
    /// cuts what does not fit, so it carries the price now and no more.
    private var inline: some View {
        Text(face.price.priceText.map { "\($0) \(face.price.unitLabel)" } ?? face.price.inlineText)
            .containerBackground(for: .widget) { Theme.ground }
    }

    /// "PLANNED 16:45", or "PLAN FROM 14:05" once old. A complication
    /// always says how old its plan is.
    private var planAge: String {
        guard let at = face.plan.readAtMs else { return face.price.fetchedText?.uppercased() ?? "" }
        let clock = ZoneClock.of(face.plan.timeZone).label(at)
        return (face.plan.state == .old ? WatchWord.planFrom : WatchWord.planned).format(clock)
    }
}
