import FTWShared
import SwiftUI
import WidgetKit

/// The plan on the watch face, as pictures with at most one figure each.
/// Circular: the dial, a ring of prices with the battery's action, the hand
/// at now and the battery's level in the middle while it is recent.
/// Rectangular: what comes next as a glyph and a time, the price now, and
/// the plan unrolled over twelve hours. Corner: the price now with the
/// day's range as a gauge. Inline: the price now.
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

    /// What comes next as a glyph and one time, then the plan unrolled
    /// over twelve hours. No sentence: the strip carries the plan. A plan
    /// over an hour old greys and shows when it was made.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: face.plan.isGrey ? "clock" : EventGlyph.name(face.plan.next?.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .widgetAccentable()
                Text(when ?? "–")
                    .font(.system(.headline, design: .default).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                if let price = shortPrice {
                    Text(price)
                        .font(.system(.body, design: .default).monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                }
            }
            if let dial = face.dial {
                DialStrip(dial: dial, quarters: 48, grey: face.plan.isGrey)
                    .frame(maxHeight: .infinity)
            }
        }
        .containerBackground(for: .widget) { Theme.ground }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.plan.summary)
    }

    /// "till 13:30" for what is under way, "22:00" for what starts later,
    /// or the time an old plan was made.
    private var when: String? {
        let clock = ZoneClock.of(face.plan.timeZone)
        if face.plan.isGrey { return face.plan.readAtMs.map { clock.label($0) } }
        guard let e = face.plan.next else { return nil }
        return PlanGlance.started(e, at: face.atMs) ? face.plan.nextUntil : clock.label(e.startMs)
    }

    /// The price now in whole minor units: "53".
    private var shortPrice: String? {
        face.price.current.map { "\(Int(PriceUnits.display($0.totalMinor, face.price.currency).rounded()))" }
    }

    /// One figure, the price now, and the day's range as a gauge along the
    /// corner: low on the left, dear on the right.
    private var corner: some View {
        Text(shortPrice ?? "–")
            .font(.system(size: 18, weight: .semibold).monospacedDigit())
            .minimumScaleFactor(0.6)
            .widgetCurvesContent()
            .widgetLabel {
                if let now = face.price.current?.totalMinor, let range = priceRange, range.lowerBound < range.upperBound {
                    Gauge(value: min(max(now, range.lowerBound), range.upperBound), in: range) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(Theme.ink)
                }
            }
            .containerBackground(for: .widget) { Theme.ground }
            .accessibilityLabel(face.price.inlineText)
    }

    private var priceRange: ClosedRange<Double>? {
        let values = face.price.curve.map(\.minor)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return lo...hi
    }

    /// The inline slot is as narrow as a date on some faces and the system
    /// cuts what does not fit, so it carries the price now and no more.
    private var inline: some View {
        Text(face.price.priceText.map { "\($0) \(face.price.unitLabel)" } ?? face.price.inlineText)
            .containerBackground(for: .widget) { Theme.ground }
    }
}
