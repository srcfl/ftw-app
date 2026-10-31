import FTWShared
import SwiftUI
import WidgetKit

/// One moment of the plan widget, in whichever family it sits. Every
/// sentence comes from `PlanGlance`; this file only lays them out.
struct PlanWidgetView: View {
    let moment: PlanGlance.Moment
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { Rectangle().fill(background) }
    }

    /// Grey when the plan is old, missing, or one the box could not make.
    private var background: AnyShapeStyle {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: return AnyShapeStyle(.clear)
        default: return AnyShapeStyle(moment.isGrey ? Theme.hairline : Theme.ground)
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: MediumPlan(moment: moment)
        case .accessoryRectangular: RectangularPlan(moment: moment)
        default: SmallPlan(moment: moment)
        }
    }
}

/// The next thing FTW does, large, and when it ends.
struct SmallPlan: View {
    let moment: PlanGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Kicker(text: PlanGlance.title)
            if let when = moment.nextWhen, let what = moment.nextWhat {
                NextEvent(when: when, what: what, until: moment.nextUntil, kind: moment.next?.kind, grey: moment.isGrey)
                Spacer(minLength: 2)
                CheapLine(moment: moment)
            } else {
                Spacer(minLength: 4)
                Text(moment.summary)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            Age(moment: moment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The next thing on the left, the next twelve hours on the right, as Now's
/// strip draws them.
struct MediumPlan: View {
    let moment: PlanGlance.Moment

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Kicker(text: PlanGlance.title)
                if let when = moment.nextWhen, let what = moment.nextWhat {
                    NextEvent(when: when, what: what, until: moment.nextUntil, kind: moment.next?.kind, grey: moment.isGrey)
                } else {
                    Text(moment.summary)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Age(moment: moment)
            }
            .frame(width: 124, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                PlanLanes(moment: moment)
                if let later = moment.laterText {
                    Text(later)
                        .font(.caption2)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The lock screen's rectangle: what happens next, until when, the cheap
/// hours, and when the box planned it.
struct RectangularPlan: View {
    static let symbol = "calendar.day.timeline.left"
    let moment: PlanGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let when = moment.nextWhen, let what = moment.nextWhat {
                Text("\(Text(when).font(.headline.monospacedDigit())) \(what)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .widgetAccentable()
                Text([moment.nextUntil, moment.cheapText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text("\(Image(systemName: Self.symbol)) \(PlanGlance.title)")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(moment.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let age = moment.ageText {
                Text(age.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Parts

/// "Now" or "02:00", large, in the colour of what happens; what; until
/// when. An old plan says it in ink: it is no longer a plan for now.
struct NextEvent: View {
    let when: String
    let what: String
    let until: String?
    let kind: PlanGlance.Kind?
    var grey = false

    var body: some View {
        Text(when)
            .font(Theme.figure(28))
            .tracking(-0.5)
            .foregroundStyle(grey ? Theme.ink2 : kind.map(Self.color) ?? Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .widgetAccentable()
        Text(what)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
        if let until {
            Text(until).font(.caption).foregroundStyle(Theme.ink2).lineLimit(1)
        }
    }

    static func color(_ kind: PlanGlance.Kind) -> Color {
        switch kind {
        case .car: return Theme.car
        case .charge: return Theme.stores
        case .discharge: return Theme.gives
        case .cheap: return Theme.ink
        }
    }
}

/// "billigast 02–04", when the hours ahead have a cheap stretch.
struct CheapLine: View {
    let moment: PlanGlance.Moment

    var body: some View {
        if let text = moment.cheapText {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// `PLANERAD 14:05`, or once old `PLAN FRÅN 14:05 · ÖPPNA FTW`: a widget
/// always says when, in the terminal layer, and never glows.
struct Age: View {
    let moment: PlanGlance.Moment

    var body: some View {
        if let text = moment.ageText {
            Text(text.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(moment.state == .old ? Theme.ink2 : Theme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// The next twelve hours as Now's strip draws them, in still paths: the car
/// and the battery as 6 pt lanes of merged runs (violet for the car with a
/// tick at its goal, cyan where the battery stores and gold where it
/// gives), an idle lane as a faint hairline, the price as bars in eight
/// levels by thirds, the hours under it, and now as a rule at the left.
///
/// In full colour the runs are a ghost at `Theme.plan`: a plan, not a
/// reading; an old plan's are ink3, as on Now. Tinted and clear home
/// screens draw in one colour: the runs solid and marked for the accent,
/// the prices faint.
struct PlanLanes: View {
    let moment: PlanGlance.Moment
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    static let lane: CGFloat = 6
    static let laneGap: CGFloat = 5
    static let strip: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let full = renderingMode == .fullColor
            let fade = moment.isGrey ? 0.45 : 1.0
            let px = 1 / max(displayScale, 1)
            let w = geo.size.width
            let from = moment.atMs, span = PlanGlance.horizonMs
            let x: (Double) -> CGFloat = { CGFloat((min(max($0, from), from + span) - from) / span) * w }
            let carY: CGFloat = 0
            let batteryY = Self.lane + Self.laneGap
            let stripTop = batteryY + Self.lane + 8
            let ink: Color = full ? Theme.ink : .primary

            ZStack(alignment: .topLeading) {
                Self.idle(y: carY + Self.lane / 2, width: w, px: px).stroke(ink.opacity(0.08), lineWidth: px)
                Self.idle(y: batteryY + Self.lane / 2, width: w, px: px).stroke(ink.opacity(0.08), lineWidth: px)
                ForEach(lanes(x: x, carY: carY, batteryY: batteryY)) { run in
                    run.path.fill(!full ? Color.primary : moment.isGrey ? Theme.ink3 : run.color.opacity(Theme.plan(contrast)))
                        .opacity(fade)
                        .widgetAccentable()
                }
                prices(x: x, top: stripTop, width: w, px: px, full: full)
                    .opacity(fade)
                Rectangle()
                    .fill(ink)
                    .frame(width: px, height: stripTop + Self.strip)
                ForEach(hours(x: x), id: \.ms) { tick in
                    Text(verbatim: tick.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(full ? AnyShapeStyle(Theme.ink3) : AnyShapeStyle(.secondary))
                        .fixedSize()
                        .position(x: min(max(tick.x, 8), w - 8), y: stripTop + Self.strip + 9)
                }
            }
        }
        .frame(height: Self.lane * 2 + Self.laneGap + 8 + Self.strip + 16)
        .accessibilityHidden(true)
    }

    struct Run: Identifiable {
        let id: String
        let path: Path
        let color: Color
    }

    /// One capsule per event, radius min(3, w/2); the car's goal as a 2 pt
    /// tick at its end.
    private func lanes(x: (Double) -> CGFloat, carY: CGFloat, batteryY: CGFloat) -> [Run] {
        moment.events.compactMap { e in
            let y: CGFloat
            let color: Color
            switch e.kind {
            case .car: (y, color) = (carY, Theme.car)
            case .charge: (y, color) = (batteryY, Theme.stores)
            case .discharge: (y, color) = (batteryY, Theme.gives)
            case .cheap: return nil
            }
            let x0 = x(e.startMs), x1 = x(e.endMs)
            guard x1 - x0 > 0.5 else { return nil }
            let rect = CGRect(x: x0, y: y, width: x1 - x0, height: Self.lane)
            var path = Path(roundedRect: rect, cornerRadius: min(3, rect.width / 2), style: .continuous)
            if e.kind == .car, e.targetPct != nil, !e.chargesAgain {
                path.addRect(CGRect(x: max(x0, x1 - 2), y: y - 2, width: 2, height: Self.lane + 4))
            }
            return Run(id: e.id, path: path, color: color)
        }
    }

    /// The prices under the plan as Now's strip draws them: a bar per slot,
    /// slot width less 1 px, its height one of eight levels and its ink by
    /// thirds of the window. No red and no green.
    private func prices(x: (Double) -> CGFloat, top: CGFloat, width: CGFloat, px: CGFloat, full: Bool) -> some View {
        let bars = moment.backdrop
        let minor = bars.map(\.minor)
        let levels = PriceBlocks.levels(minor), thirds = PriceBlocks.thirds(minor)
        var paths: [PriceChart.Third: Path] = [.cheap: Path(), .middle: Path(), .dear: Path()]
        for (i, b) in bars.enumerated() {
            let x0 = x(b.startMs), x1 = x(b.endMs)
            guard x1 - x0 > px else { continue }
            let h = Self.strip * CGFloat(levels[i]) / 8
            paths[thirds[i]]?.addRect(CGRect(x: x0 + px, y: top + Self.strip - h, width: max(px, x1 - x0 - px), height: h))
        }
        let ink: Color = full ? Theme.ink : .primary
        return ZStack(alignment: .topLeading) {
            paths[.cheap]!.fill(ink.opacity(full ? 0.32 : 0.2))
            paths[.middle]!.fill(ink.opacity(full ? 0.5 : 0.3))
            paths[.dear]!.fill(ink.opacity(full ? 0.8 : 0.45))
        }
    }

    /// Local hours on three-hour boundaries, kept clear of now.
    private func hours(x: (Double) -> CGFloat) -> [(ms: Double, x: CGFloat, label: String)] {
        let clock = ZoneClock.of(moment.timeZone)
        let hour = PriceBlocks.hourMs
        var out: [(ms: Double, x: CGFloat, label: String)] = []
        var t = clock.alignDown(moment.atMs, stepMs: hour) + hour
        while t < moment.atMs + PlanGlance.horizonMs - hour / 2 {
            let minute = clock.minuteOfDay(t)
            if minute % 180 == 0, t - moment.atMs >= hour {
                out.append((t, x(t), String(clock.label(t).prefix(2))))
            }
            t += hour
        }
        return out
    }

    private static func idle(y: CGFloat, width: CGFloat, px: CGFloat) -> Path {
        var p = Path()
        let snapped = (y / px).rounded() * px + px / 2
        p.move(to: CGPoint(x: 0, y: snapped))
        p.addLine(to: CGPoint(x: width, y: snapped))
        return p
    }
}
