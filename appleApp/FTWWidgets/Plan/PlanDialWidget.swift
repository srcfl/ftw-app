import FTWShared
import SwiftUI
import WidgetKit

/// The plan dial on the home screen, in StandBy and on the lock screen,
/// from the plan the app left in the App Group. It opens no connection.
/// The hand moves on by the quarter hour; an hour after the plan was made
/// the dial goes grey and says how old the plan is.
struct PlanDialWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "energy.ftw.plan-dial", provider: PlanDialTimeline()) { entry in
            PlanDialWidgetView(entry: entry)
        }
        .configurationDisplayName(PlanGlance.dialTitle)
        .description(PlanGlance.dialSummary)
        .supportedFamilies([.systemSmall, .accessoryCircular])
        // The dial is round and fills its square; it keeps its own margin.
        .contentMarginsDisabled()
    }
}

struct PlanDialEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has left no plan.
    let face: PlanDial.Face?
    let moment: PlanGlance.Moment
    let level: PlanEntry.Level?

    var nowMs: Double { date.timeIntervalSince1970 * 1000 }
}

struct PlanDialTimeline: TimelineProvider {
    /// How far ahead one timeline runs; WidgetKit asks again at its end.
    static let aheadMs: Double = 12 * 3_600_000

    func placeholder(in context: Context) -> PlanDialEntry {
        let now = Date.now.timeIntervalSince1970 * 1000
        return Self.entries(PlanDialTimeline.sample(nowMs: now), now: now, count: 1)[0]
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanDialEntry) -> Void) {
        let now = Date.now.timeIntervalSince1970 * 1000
        let read = Self.read()
        // The gallery shows the shape of a plan, not an empty dial.
        completion(Self.entries(read == nil && context.isPreview ? Self.sample(nowMs: now) : read, now: now, count: 1)[0])
    }

    /// One entry now and one at every quarter hour after it, so the hand
    /// and the dimming move on. The app reloads every timeline after it
    /// writes a new plan.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanDialEntry>) -> Void) {
        let now = Date.now.timeIntervalSince1970 * 1000
        let entries = Self.entries(Self.read(), now: now, count: Int(Self.aheadMs / PlanDial.quarterMs) + 1)
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func read() -> CacheRead<PlanEntry>? {
        let reader = CacheReader.shared()
        return reader.flatMap { r in r.latestSiteID(PlanEntry.self).flatMap { r.read(PlanEntry.self, siteId: $0) } }
    }

    /// The face is worked out once per day it shows, not once per entry.
    static func entries(_ read: CacheRead<PlanEntry>?, now: Double, count: Int) -> [PlanDialEntry] {
        let calendar = Calendar.household(read?.value.timeZone)
        var faces = [Date: PlanDial.Face]()
        var out = [PlanDialEntry]()
        var t = now
        for k in 0..<count {
            if k > 0 { t = ((now / PlanDial.quarterMs).rounded(.down) + Double(k)) * PlanDial.quarterMs }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: t / 1000))
            var face: PlanDial.Face?
            if let read {
                face = faces[day] ?? PlanDial.face(read.value, nowMs: t, calendar: calendar)
                faces[day] = face
            }
            out.append(PlanDialEntry(
                date: Date(timeIntervalSince1970: t / 1000),
                face: face,
                moment: PlanGlance.moment(read, atMs: t, calendar: calendar),
                level: read?.value.batteryLevel
            ))
        }
        return out
    }

    /// A day's plan for the gallery and the placeholder. Never shown as the
    /// home's plan.
    static func sample(nowMs: Double) -> CacheRead<PlanEntry> {
        let hour: Double = 3_600_000
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000)).timeIntervalSince1970 * 1000
        let battery = (0..<96).map { i -> PlanEntry.Slot in
            let h = Double(i) / 4
            let w: Double = h >= 2 && h < 5 ? 3_000 : (h >= 10 && h < 15 ? 2_500 : (h >= 17 && h < 21 ? -2_000 : 0))
            return PlanEntry.Slot(startMs: start + Double(i) * hour / 4, durationMs: hour / 4, batteryW: w, reason: "idle")
        }
        let prices = (0..<24).map { i -> PriceSlot in
            let wave: Double = sin(Double(i - 9) / 24 * 2 * Double.pi)
            let total: Double = 110 + 50 * wave + Double((i * 37) % 20)
            return PriceSlot(startMs: start + Double(i) * hour, durationMs: hour, spotMinor: 40, totalMinor: total)
        }
        let entry = PlanEntry(
            battery: battery,
            charges: [.init(loadpointID: "car", fromMs: start + 2 * hour, toMs: start + 5 * hour, energyWh: 20_000, targetPct: 80)],
            prices: prices,
            currency: "SEK",
            boxStale: false,
            daylight: .init(covered: .init(fromMs: start, toMs: start + 48 * hour), sun: [.init(fromMs: start + 7.5 * hour, toMs: start + 17.5 * hour), .init(fromMs: start + 31.5 * hour, toMs: start + 41.5 * hour)]),
            batteryLevel: .init(percent: 64, readAtMs: nowMs)
        )
        return CacheRead(record: CacheRecord(siteId: "", carrier: .none, srcState: .live, readAtMs: nowMs, value: entry), origin: .app)
    }
}

/// The battery's level as a widget may show it: plainly while fresh,
/// quietly for a while, then not at all.
enum WidgetLevel {
    static let freshMs: Double = 15 * 60_000

    static func shown(_ level: PlanEntry.Level?, at t: Double) -> (pct: Double, old: Bool)? {
        guard let level else { return nil }
        let age = t - level.readAtMs
        guard age < PlanGlance.staleAfterMs else { return nil }
        return (level.percent, age >= freshMs)
    }
}

struct PlanDialWidgetView: View {
    let entry: PlanDialEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        content
            .containerBackground(for: .widget) {
                // The glass's own dark, so the dial and its square are one.
                Rectangle().fill(family == .systemSmall ? AnyShapeStyle(PlanDialPalette.widget.glass) : AnyShapeStyle(.clear))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PlanGlance.dialTitle)
            .accessibilityValue(spoken)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            CircularDial(entry: entry)
        default:
            if let face = entry.face {
                let level = WidgetLevel.shown(entry.level, at: entry.nowMs)
                PlanDialView(
                    face: face,
                    nowMs: entry.nowMs,
                    palette: .widget,
                    batteryPct: level?.pct,
                    batteryOld: level?.old ?? false,
                    labels: false,
                    compact: true,
                    grey: entry.moment.isGrey,
                    monochrome: renderingMode != .fullColor,
                    still: true,
                    note: PlanDial.tomorrowNote(face, nowMs: entry.nowMs, short: true),
                    caption: entry.moment.isGrey ? entry.moment.ageText.map(Self.short) : nil
                )
                .padding(6)
            } else {
                Text(entry.moment.summary)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Pair(0xA0A0A0, 0xA0A0A0))
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
        }
    }

    /// "Plan from 14:05 · open FTW" is too long for the middle: the time
    /// alone, after the plan's own word.
    private static func short(_ age: String) -> String {
        age.components(separatedBy: " · ").first ?? age
    }

    private var spoken: String {
        var parts = [entry.moment.summary]
        if let level = WidgetLevel.shown(entry.level, at: entry.nowMs) { parts.append(PlanDial.percent(level.pct)) }
        if let age = entry.moment.ageText { parts.append(age) }
        return parts.joined(separator: ", ")
    }
}

/// The lock screen's circle: today round the rim as short ticks, the hand
/// at now, and the battery as a ring around its level.
struct CircularDial: View {
    let entry: PlanDialEntry

    var body: some View {
        let level = WidgetLevel.shown(entry.level, at: entry.nowMs)
        ZStack {
            AccessoryWidgetBackground()
            Canvas { ctx, size in draw(&ctx, size: size) }
            if let level {
                Circle()
                    .trim(from: 0, to: max(0, min(1, level.pct / 100)))
                    .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .padding(13)
                    .opacity(level.old ? 0.5 : 1)
                    .widgetAccentable()
                Text(verbatim: "\(Int(level.pct.rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .opacity(level.old ? 0.6 : 1)
                    .padding(.horizontal, 15)
            } else {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.7)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let face = entry.face else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Double(min(size.width, size.height)) / 2
        let now = face.index(at: entry.nowMs) ?? -1
        let turn = now >= 0 ? face.quarters[now].turn : 0
        let grey = entry.moment.isGrey
        func point(_ f: Double, _ rr: Double) -> CGPoint {
            let u = PlanDial.unit(f)
            return CGPoint(x: c.x + u.x * rr, y: c.y + u.y * rr)
        }
        // Today's quarters, or tomorrow's once it is tomorrow's turn: a tick
        // each, as long as the price, as strong as what the battery does.
        for (i, q) in face.quarters.enumerated() where q.turn == turn {
            guard let price = q.priceMinor else { continue }
            var alpha: Double
            switch grey ? .wait : q.action {
            case .store: alpha = 1
            case .use: alpha = 0.75
            case .wait: alpha = 0.45
            case .unplanned: alpha = 0.3
            }
            if i < now { alpha *= 0.45 }
            let length = max(0.05, min(1, abs(price) / face.scale) * 0.2)
            var tick = Path()
            tick.move(to: point(q.dayFraction, r * 0.75))
            tick.addLine(to: point(q.dayFraction, r * (0.75 + length)))
            ctx.stroke(tick, with: .color(.white.opacity(alpha)), lineWidth: max(1, 2 * Double.pi * r * 0.8 / 96 * 0.7))
        }
        // Now.
        let f = face.progress(at: entry.nowMs).truncatingRemainder(dividingBy: 1)
        var hand = Path()
        hand.move(to: point(f, r * 0.66))
        hand.addLine(to: point(f, r * 0.99))
        ctx.stroke(hand, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

extension PlanDialPalette {
    /// The app's tokens as they resolve dark (`Theme.xcassets`), since the
    /// dial sits on its own dark glass: cyan stores, white is used, grey
    /// waits, gold is the sun.
    static let widget = PlanDialPalette(
        store: Pair(0x13DCF6, 0x13DCF6).dark,
        use: Pair(0xE8E8E8, 0xE8E8E8).dark,
        wait: Pair(0x858585, 0x858585).dark,
        car: Pair(0xCCA8FF, 0xCCA8FF).dark,
        sun: Pair(0xFFB000, 0xFFB000).dark,
        hand: Pair(0xE8E8E8, 0xE8E8E8).dark,
        battery: Pair(0x13DCF6, 0x13DCF6).dark,
        quiet: Pair(0xA0A0A0, 0xA0A0A0).dark,
        glass: Pair(0x0D0D0D, 0x0D0D0D).dark
    )
}
