import FTWShared
import SwiftUI
import WidgetKit

/// The plan dial in StandBy, on the home screen and as a circle on the
/// lock screen, from the plan the app left in the App Group. The same face
/// as the plan view and the watch, in the watch's material: a still path
/// on a dark ground, nothing glowing. It opens no connection. The hand
/// moves on by the quarter hour; an hour after the box made the plan the
/// dial goes grey and says how old the plan is.
struct PlanDialWidget: Widget {
    static let kind = "energy.ftw.plan-dial"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PlanDialTimeline()) { entry in
            PlanDialWidgetView(entry: entry)
        }
        .configurationDisplayName(PlanDial.title)
        .description(PlanDial.summary)
        // systemSmall is also the StandBy widget.
        .supportedFamilies([.systemSmall, .accessoryCircular])
        // The dial is round and fills its square; it keeps its own margin.
        .contentMarginsDisabled()
    }
}

struct PlanDialEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has left no plan and no prices.
    let dial: PlanDial?
    let moment: PlanGlance.Moment
    /// When the box made the plan, or nil without one.
    let plannedAtMs: Double?
}

struct PlanDialTimeline: TimelineProvider {
    /// How far ahead one timeline runs; the app reloads it with each plan.
    static let aheadMs: Double = 12 * 3_600_000

    func placeholder(in context: Context) -> PlanDialEntry {
        let now = Date.now.timeIntervalSince1970 * 1000
        return Self.entries(Self.sample(nowMs: now), nowMs: now, count: 1)[0]
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanDialEntry) -> Void) {
        let now = Date.now.timeIntervalSince1970 * 1000
        let read = Self.read()
        // The gallery shows the shape of a plan, not an empty dial.
        completion(Self.entries(read == nil && context.isPreview ? Self.sample(nowMs: now) : read, nowMs: now, count: 1)[0])
    }

    /// One entry now and one at each quarter hour after it, so the hand
    /// moves without waking the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanDialEntry>) -> Void) {
        let now = Date.now.timeIntervalSince1970 * 1000
        let entries = Self.entries(Self.read(), nowMs: now, count: Int(Self.aheadMs / PlanDial.quarterMs) + 1)
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func read() -> CacheRead<PlanEntry>? {
        let reader = CacheReader.shared()
        return reader.flatMap { r in r.latestSiteID(PlanEntry.self).flatMap { r.read(PlanEntry.self, siteId: $0) } }
    }

    static func entries(_ read: CacheRead<PlanEntry>?, nowMs: Double, count: Int) -> [PlanDialEntry] {
        (0..<count).map { k in
            let t = k == 0 ? nowMs : ((nowMs / PlanDial.quarterMs).rounded(.down) + Double(k)) * PlanDial.quarterMs
            return PlanDialEntry(
                date: Date(timeIntervalSince1970: t / 1000),
                dial: read.map { PlanDial(plan: $0.value, prices: nil, nowMs: t) },
                moment: PlanGlance.moment(read, atMs: t),
                plannedAtMs: read?.record.readAtMs
            )
        }
    }

    /// A day's plan for the gallery and the placeholder. Never shown as the
    /// home's plan.
    static func sample(nowMs: Double) -> CacheRead<PlanEntry> {
        let hour: Double = 3_600_000
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000)).timeIntervalSince1970 * 1000
        let battery = (0..<192).map { i -> PlanEntry.Slot in
            let h = (Double(i) / 4).truncatingRemainder(dividingBy: 24)
            let w: Double = h >= 2 && h < 5 ? 3_000 : (h >= 10 && h < 15 ? 2_500 : (h >= 17 && h < 21 ? -2_000 : 0))
            return PlanEntry.Slot(startMs: start + Double(i) * hour / 4, durationMs: hour / 4, batteryW: w, reason: "idle")
        }
        let prices = (0..<48).map { i -> PriceSlot in
            let wave = sin(Double(i % 24 - 9) / 24 * 2 * .pi)
            return PriceSlot(startMs: start + Double(i) * hour, durationMs: hour, spotMinor: 40, totalMinor: 110 + 50 * wave + Double((i * 37) % 20))
        }
        let entry = PlanEntry(
            battery: battery,
            charges: [.init(loadpointID: "car", fromMs: start + 26 * hour, toMs: start + 29 * hour, energyWh: 20_000, targetPct: 80)],
            prices: prices,
            currency: "SEK",
            boxStale: false,
            daylight: .init(covered: .init(fromMs: start, toMs: start + 48 * hour), sun: [.init(fromMs: start + 7.5 * hour, toMs: start + 17.5 * hour), .init(fromMs: start + 31.5 * hour, toMs: start + 41.5 * hour)])
        )
        return CacheRead(record: CacheRecord(siteId: "", carrier: .none, srcState: .live, readAtMs: nowMs, value: entry), origin: .app)
    }
}

struct PlanDialWidgetView: View {
    let entry: PlanDialEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                // The watch's material: the dial on its own dark ground in
                // either scheme, so it reads on any wallpaper and in StandBy
                // at night.
                if family == .systemSmall { Theme.ground.environment(\.colorScheme, .dark) } else { Color.clear }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PlanDial.title)
            .accessibilityValue(entry.moment.summary)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circle
        default: small.environment(\.colorScheme, .dark)
        }
    }

    /// StandBy and the home screen: the dial with the price now in the
    /// middle, and under it when the box made the plan, always.
    private var small: some View {
        GeometryReader { geo in
            let room = min(geo.size.width, geo.size.height)
            let side = room - 26
            VStack(spacing: 3) {
                if let dial = entry.dial {
                    ZStack {
                        PlanDialView(dial: dial, grey: entry.moment.isGrey, size: .small)
                        VStack(spacing: 0) {
                            Text(dial.figure(0))
                                .font(Theme.figure(side * 0.17))
                                .foregroundStyle(entry.moment.isGrey ? Theme.ink3 : Theme.ink)
                            Text(PriceUnits.unit(dial.currency).perKwh.uppercased())
                                .font(.system(size: max(7, side * 0.052), weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink2)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: side * 0.42)
                    }
                    .frame(width: side, height: side)
                    Text(planned(dial) ?? " ")
                        .font(.system(size: max(7, room * 0.05), weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(entry.moment.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The lock screen: the dial and the price now.
    private var circle: some View {
        ZStack {
            if let dial = entry.dial {
                PlanDialView(dial: dial, grey: entry.moment.isGrey, size: .small)
                Text(figure(dial))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()
            } else {
                Circle().stroke(Theme.ink3, lineWidth: 1)
            }
        }
    }

    /// "98", the price in the quarter running now.
    private func figure(_ dial: PlanDial) -> String { dial.figure(0) }

    /// "PLANNED 16:45", or once old, "PLAN FROM 14:05 · OLD".
    private func planned(_ dial: PlanDial) -> String? {
        entry.plannedAtMs.map { PlanDial.planned(atMs: $0, old: entry.moment.state == .old, zone: dial.zone).components(separatedBy: " · ").first ?? "" }
    }
}
