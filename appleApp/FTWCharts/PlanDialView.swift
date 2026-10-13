import FTWShared
import SwiftUI

/// The colours the plan dial draws with. The dial always sits on its own
/// dark glass, so these are the dark scheme's: the app hands over its
/// tokens resolved dark, the widget its copies of them.
struct PlanDialPalette: Equatable {
    /// The battery stores.
    var store: Color
    /// The battery is used.
    var use: Color
    /// The battery waits.
    var wait: Color
    /// A quarter when the car charges.
    var car: Color
    /// Day on the rim, where the box's forecast expects sun.
    var sun: Color
    /// The hand and the figures.
    var hand: Color
    /// The battery's ring.
    var battery: Color
    /// Ticks, hour labels, the spiral's guide, small words.
    var quiet: Color
    /// The glass behind it all.
    var glass: Color
}

/// The quarter a finger, VoiceOver or later the Crown marks on the dial.
/// Only the mark and the middle read it, so when it moves they redraw and
/// nothing else does.
@MainActor
@Observable
final class PlanDialSelection {
    var index: Int?
}

/// FTW's plan as a round dial: today the inner turn of a spiral, tomorrow
/// the outer, a bar per quarter hour as tall as the price and coloured by
/// what the plan does with the battery. Midnight at the bottom, noon at the
/// top, up on the left and down on the right, like the sun. A hand marks
/// now and what has passed dims. In the middle, the battery as a ring and
/// the time and the price.
///
/// The app, the widgets and later the Watch draw this same view. It draws;
/// a finger or the Crown belongs to whoever holds it, and marks a quarter
/// through `selection`. Each layer redraws only when what it shows
/// changes: the bars when the plan or the quarter does, the hand by the
/// minute, the mark and the middle as the finger moves.
struct PlanDialView: View {
    let face: PlanDial.Face
    let nowMs: Double
    let palette: PlanDialPalette
    /// The battery's level, whole percent. Nil when there is no reading.
    var batteryPct: Double?
    /// The reading is old: the ring shows it quietly.
    var batteryOld = false
    /// The quarter under a finger or the Crown. Nil where nothing can
    /// mark one, as in a widget.
    var selection: PlanDialSelection?
    /// Hour labels inside the rim. The app has room for them.
    var labels = true
    /// The middle without the price's unit, for a widget's small dial.
    var compact = false
    /// The plan is old or the box could not make one: grey, never coloured.
    var grey = false
    /// One colour, for tinted widgets and StandBy at night.
    var monochrome = false
    /// No motion: widgets, Reduce Motion, Low Power Mode.
    var still = false
    /// Prices are on their way: the stretch without them is drawn faint.
    var fetching = false
    /// A quiet line in the empty outer turn.
    var note: String?
    /// A line under the price, such as how old the plan is.
    var caption: String?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // The labels sit inside the glass, on its rim.
            let radius = labels ? side / 2 / 1.14 : side / 2
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [palette.glass.opacity(0.97), palette.glass.opacity(0.9)], center: .center, startRadius: 0, endRadius: side / 2))
                    .overlay(Circle().strokeBorder(palette.quiet.opacity(0.18), lineWidth: 0.5))
                DialBars(
                    face: face,
                    nowIndex: nowIndex,
                    skyFromMs: quarterStart,
                    radius: radius,
                    palette: palette,
                    labels: labels,
                    grey: grey,
                    monochrome: monochrome,
                    still: still,
                    fetching: fetching
                )
                .equatable()
                if let selection {
                    DialMark(face: face, selection: selection, radius: radius, palette: palette, grey: grey, monochrome: monochrome)
                }
                DialHand(face: face, minute: minute, radius: radius, color: palette.hand)
                    .equatable()
                DialCentre(
                    face: face,
                    minute: minute,
                    selection: selection,
                    radius: radius,
                    palette: palette,
                    batteryPct: batteryPct,
                    batteryOld: batteryOld || grey,
                    monochrome: monochrome,
                    compact: compact,
                    still: still,
                    caption: caption
                )
                if let note {
                    Text(note)
                        .font(.system(size: max(9, radius * 0.06), weight: .medium))
                        .foregroundStyle(palette.quiet)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(width: radius * (compact ? 1.1 : 0.9))
                        // The top of the outer turn, where tomorrow's noon would stand.
                        .offset(y: -radius * (PlanDial.Layout.spiral(1.5) + PlanDial.Layout.bar * 0.42))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
    }

    /// The dial marks the minute.
    private var minute: Double { (nowMs / 60_000).rounded(.down) * 60_000 }

    private var quarterStart: Double { (nowMs / PlanDial.quarterMs).rounded(.down) * PlanDial.quarterMs }

    /// The quarter now, or past either end of the face.
    private var nowIndex: Int {
        face.index(at: nowMs) ?? (nowMs < face.dayStartMs ? -1 : face.quarters.count)
    }
}

/// The sky band's arcs, as shares of the day.
private struct Sky: Equatable {
    var covered: [ClosedRange<Double>]
    var sun: [ClosedRange<Double>]

    init(_ arcs: (covered: [ClosedRange<Double>], sun: [ClosedRange<Double>])) {
        covered = arcs.covered
        sun = arcs.sun
    }
}

/// One change of the bars, followed while it moves: each bar that changed
/// springs from the length it was drawn at to its new one, a few
/// milliseconds after the bar before it, so a new plan grows into shape
/// round the spiral instead of jumping.
private struct DialMotion {
    var from: [Double: Double] = [:]
    var order: [Double: Int] = [:]
    var began = Date.distantPast
    var stagger = ChartMotion.stagger

    var duration: Double { order.isEmpty ? 0 : ChartMotion.settle + Double(order.count) * stagger }

    func length(_ id: Double, _ target: Double, at date: Date) -> Double {
        guard let i = order[id], let start = from[id] else { return target }
        let f = ChartMotion.spring(date.timeIntervalSince(began) - Double(i) * stagger)
        return start + (target - start) * f
    }

    /// From the lengths as drawn to `new`, in the order of `ids`. A bar that
    /// is new grows from nothing.
    static func between(_ drawn: [Double: Double], _ new: [Double: Double], ids: [Double], at date: Date, still: Bool) -> DialMotion {
        var m = DialMotion(began: date)
        guard !still else { return m }
        var k = 0
        for id in ids {
            guard let target = new[id] else { continue }
            let was = drawn[id] ?? 0
            guard abs(was - target) > 0.004 else { continue }
            m.from[id] = was
            m.order[id] = k
            k += 1
        }
        if k > 0 { m.stagger = min(ChartMotion.stagger, ChartMotion.staggerCap / Double(k)) }
        return m
    }
}

/// The face: the sky, the ticks, the spiral and its bars. Redrawn when the
/// plan changes or a quarter passes, and at the display's rate only while
/// a new plan grows in.
private struct DialBars: View, Equatable {
    let face: PlanDial.Face
    let nowIndex: Int
    /// The sky runs for the 24 hours from here.
    let skyFromMs: Double
    let radius: CGFloat
    let palette: PlanDialPalette
    let labels: Bool
    let grey: Bool
    let monochrome: Bool
    let still: Bool
    let fetching: Bool

    @State private var shown: [Double: Double] = [:]
    @State private var motion = DialMotion()
    @State private var moving = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.face == b.face && a.nowIndex == b.nowIndex && a.skyFromMs == b.skyFromMs && a.radius == b.radius && a.palette == b.palette
            && a.labels == b.labels && a.grey == b.grey && a.monochrome == b.monochrome && a.still == b.still && a.fetching == b.fetching
    }

    var body: some View {
        let sky = Sky(face.sky(nowMs: skyFromMs))
        if still {
            // A widget, or no motion: the bars as they are, nothing to follow.
            let lengths = Self.targets(face)
            Canvas { ctx, size in draw(&ctx, size: size, sky: sky, lengths: lengths, at: .distantFuture) }
        } else {
            TimelineView(.animation(paused: !moving)) { context in
                let at = moving ? context.date : .distantFuture
                Canvas { ctx, size in draw(&ctx, size: size, sky: sky, lengths: shown, at: at) }
            }
            .onAppear { begin() }
            .onChange(of: face) { begin() }
        }
    }

    /// Each bar's length as a share of the longest, signed as its price.
    private static func targets(_ face: PlanDial.Face) -> [Double: Double] {
        var out = [Double: Double]()
        for q in face.quarters {
            if let p = q.priceMinor { out[q.id] = p / face.scale }
        }
        return out
    }

    private func begin() {
        let new = Self.targets(face)
        let now = Date()
        var drawn = [Double: Double]()
        for (id, target) in shown { drawn[id] = motion.length(id, target, at: now) }
        motion = DialMotion.between(drawn, new, ids: face.quarters.map(\.id), at: now, still: still)
        shown = new
        guard motion.duration > 0 else {
            moving = false
            return
        }
        moving = true
        let began = motion.began
        let length = motion.duration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(length + 0.05))
            if motion.began == began { moving = false }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, sky: Sky, lengths: [Double: Double], at date: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Double(radius)
        func point(_ f: Double, _ rr: Double) -> CGPoint {
            let u = PlanDial.unit(f)
            return CGPoint(x: c.x + u.x * rr, y: c.y + u.y * rr)
        }
        func arc(_ range: ClosedRange<Double>, _ rr: Double) -> Path {
            var path = Path()
            let steps = max(2, Int((range.upperBound - range.lowerBound) * 240))
            for k in 0...steps {
                let f = range.lowerBound + (range.upperBound - range.lowerBound) * Double(k) / Double(steps)
                k == 0 ? path.move(to: point(f, rr)) : path.addLine(to: point(f, rr))
            }
            return path
        }
        func spiral(_ from: Double, _ to: Double, lift: Double) -> Path {
            var path = Path()
            let steps = max(2, Int((to - from) * 192))
            for k in 0...steps {
                let p = from + (to - from) * Double(k) / Double(steps)
                let pt = point(p.truncatingRemainder(dividingBy: 1), r * (PlanDial.Layout.spiral(p) + lift))
                k == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            return path
        }
        let L = PlanDial.Layout.self
        let quiet = monochrome ? palette.hand : palette.quiet

        // The sky on the rim, from the box's own forecast: where it speaks,
        // night is a faint line and day is the sun's colour.
        for a in sky.covered {
            ctx.stroke(arc(a, r * L.rim), with: .color(quiet.opacity(0.22)), lineWidth: r * L.band)
        }
        for a in sky.sun {
            ctx.stroke(arc(a, r * L.rim), with: .color((monochrome ? palette.hand : palette.sun).opacity(0.9)), lineWidth: r * L.band)
        }

        // Ticks on the band, and the four hours that name the day.
        for h in 0..<24 {
            let major = h % 6 == 0
            guard major || labels else { continue }
            let f = Double(h) / 24
            let inner = r * (L.rim - L.band / 2 - (major ? 0.018 : 0.008))
            let outer = r * (L.rim + (major ? L.band / 2 + 0.012 : -L.band / 2))
            var tick = Path()
            tick.move(to: point(f, inner))
            tick.addLine(to: point(f, outer))
            ctx.stroke(tick, with: .color(quiet.opacity(major ? 0.7 : 0.35)), lineWidth: major ? max(1, r * 0.008) : max(0.5, r * 0.004))
        }
        if labels {
            for h in [0, 6, 12, 18] {
                let label = Text(String(format: "%02d", h))
                    .font(.system(size: max(8, r * 0.07), weight: .semibold, design: .monospaced))
                    .foregroundStyle(quiet.opacity(0.85))
                ctx.draw(label, at: point(Double(h) / 24, r * 1.075))
            }
        }

        // The spiral itself: today firm, tomorrow fainter, and dotted while
        // the box has no prices for it.
        ctx.stroke(spiral(0, 1, lift: 0), with: .color(quiet.opacity(0.3)), lineWidth: max(0.5, r * 0.005))
        ctx.stroke(spiral(1, 2, lift: 0), with: .color(quiet.opacity(face.tomorrowPriced ? 0.22 : 0.3)),
                   style: StrokeStyle(lineWidth: max(0.5, r * 0.005), dash: face.tomorrowPriced ? [] : [1, max(2, r * 0.02)]))

        // A stretch being fetched: a faint band where its bars will grow.
        if fetching {
            var i = max(0, nowIndex)
            while i < face.quarters.count {
                guard face.quarters[i].priceMinor == nil else {
                    i += 1
                    continue
                }
                var j = i
                while j + 1 < face.quarters.count, face.quarters[j + 1].priceMinor == nil { j += 1 }
                let from = Double(face.quarters[i].turn) + Double(face.quarters[i].minuteOfDay) / 1440
                let to = face.quarters[j].progress + 7.5 / 1440
                ctx.stroke(spiral(from, to, lift: L.bar / 2), with: .color(quiet.opacity(0.08)), lineWidth: r * L.bar)
                i = j + 1
            }
        }

        // The bars, and the car's dots inside the spiral.
        for (i, q) in face.quarters.enumerated() {
            let past = i < nowIndex
            let f = q.dayFraction
            let base = L.spiral(q.progress)
            if q.car {
                let dot = point(f, r * (base - 0.03))
                let d = max(1.6, r * 0.022)
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - d / 2, y: dot.y - d / 2, width: d, height: d)),
                         with: .color((monochrome ? palette.hand : palette.car).opacity(past ? 0.35 : 1)))
            }
            guard let target = lengths[q.id] else { continue }
            let length = motion.length(q.id, target, at: date)
            let (color, alpha) = style(q, past: past)
            let foot = r * (base + 0.008)
            let reach = length >= 0 ? max(0.012, length * L.bar) : -min(L.barInward, -length * L.bar)
            var bar = Path()
            bar.move(to: point(f, foot))
            bar.addLine(to: point(f, foot + r * reach))
            let width = max(1, 2 * Double.pi * foot / 96 * 0.56)
            ctx.stroke(bar, with: .color(color.opacity(alpha)), lineWidth: width)
        }
    }

    /// A bar's colour and strength: what the plan does, dimmed once past.
    private func style(_ q: PlanDial.Quarter, past: Bool) -> (Color, Double) {
        var color: Color
        var alpha: Double
        if monochrome {
            color = palette.hand
            switch grey ? .wait : q.action {
            case .store: alpha = 1
            case .use: alpha = 0.7
            case .wait: alpha = 0.38
            case .unplanned: alpha = 0.26
            }
        } else if grey {
            color = palette.wait
            alpha = 0.6
        } else {
            switch q.action {
            case .store: (color, alpha) = (palette.store, 1)
            case .use: (color, alpha) = (palette.use, 1)
            case .wait: (color, alpha) = (palette.wait, 1)
            case .unplanned: (color, alpha) = (palette.wait, 0.5)
            }
        }
        return (color, past ? alpha * 0.36 : alpha)
    }
}

/// The quarter under a finger: a fine rule across the spiral, and its bar
/// drawn bright over the rest.
private struct DialMark: View {
    let face: PlanDial.Face
    let selection: PlanDialSelection
    let radius: CGFloat
    let palette: PlanDialPalette
    let grey: Bool
    let monochrome: Bool

    var body: some View {
        if let index = selection.index, face.quarters.indices.contains(index) {
            mark(index)
        }
    }

    private func mark(_ index: Int) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = Double(radius)
            let q = face.quarters[index]
            let u = PlanDial.unit(q.dayFraction)
            func point(_ rr: Double) -> CGPoint { CGPoint(x: c.x + u.x * rr, y: c.y + u.y * rr) }
            let base = PlanDial.Layout.spiral(q.progress)
            var rule = Path()
            rule.move(to: point(r * (base - 0.06)))
            rule.addLine(to: point(r * (base + PlanDial.Layout.bar + 0.04)))
            ctx.stroke(rule, with: .color(palette.hand.opacity(0.55)), lineWidth: 1)
            if let price = q.priceMinor {
                let foot = r * (base + 0.008)
                let length = price / face.scale
                let reach = length >= 0 ? max(0.012, length * PlanDial.Layout.bar) : -min(PlanDial.Layout.barInward, -length * PlanDial.Layout.bar)
                var bar = Path()
                bar.move(to: point(foot))
                bar.addLine(to: point(foot + r * reach))
                let color: Color
                if monochrome || grey {
                    color = palette.hand
                } else {
                    switch q.action {
                    case .store: color = palette.store
                    case .use, .unplanned: color = palette.hand
                    case .wait: color = palette.hand.opacity(0.8)
                    }
                }
                ctx.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: max(2, 2 * Double.pi * foot / 96 * 0.9), lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Now: a hand from the battery's ring to the rim, and a dot where it
/// crosses the spiral. Redrawn by the minute and nothing else.
private struct DialHand: View, Equatable {
    let face: PlanDial.Face
    let minute: Double
    let radius: CGFloat
    let color: Color

    /// The hand reads only the face's day and clock.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.minute == b.minute && a.radius == b.radius && a.color == b.color
            && a.face.dayStartMs == b.face.dayStartMs && a.face.timeZoneID == b.face.timeZoneID
    }

    var body: some View {
        let progress = face.progress(at: minute)
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = Double(radius)
            let L = PlanDial.Layout.self
            let u = PlanDial.unit(progress.truncatingRemainder(dividingBy: 1))
            func point(_ rr: Double) -> CGPoint { CGPoint(x: c.x + u.x * rr, y: c.y + u.y * rr) }
            var hand = Path()
            hand.move(to: point(r * (L.battery + L.batteryWidth / 2 + 0.025)))
            hand.addLine(to: point(r * (L.rim + L.band / 2 + 0.01)))
            ctx.stroke(hand, with: .color(color), style: StrokeStyle(lineWidth: max(1.2, r * 0.011), lineCap: .round))
            let dot = point(r * L.spiral(progress))
            let d = max(4, r * 0.045)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - d / 2, y: dot.y - d / 2, width: d, height: d)), with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

/// The middle: the battery as a ring, then the time and the price in mono
/// figures, now or at the marked quarter.
private struct DialCentre: View {
    let face: PlanDial.Face
    let minute: Double
    let selection: PlanDialSelection?
    let radius: CGFloat
    let palette: PlanDialPalette
    let batteryPct: Double?
    let batteryOld: Bool
    let monochrome: Bool
    let compact: Bool
    let still: Bool
    let caption: String?

    var body: some View {
        let centre = PlanDial.centre(face, nowMs: minute, selected: selection?.index)
        let L = PlanDial.Layout.self
        let ring = radius * 2 * L.battery
        let width = radius * L.batteryWidth
        ZStack {
            Circle()
                .stroke(palette.quiet.opacity(0.2), lineWidth: width)
                .frame(width: ring, height: ring)
            if let batteryPct {
                Circle()
                    .trim(from: 0, to: max(0, min(1, batteryPct / 100)))
                    .stroke(batteryOld ? palette.quiet.opacity(0.7) : (monochrome ? palette.hand : palette.battery), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    // From midnight round, as the day runs.
                    .rotationEffect(.degrees(90))
                    .frame(width: ring, height: ring)
                    .animation(still ? nil : .spring(response: ChartMotion.response, dampingFraction: ChartMotion.damping), value: batteryPct)
            }
            VStack(spacing: radius * 0.012) {
                if let day = centre.day {
                    Text(day.uppercased())
                        .font(.system(size: max(7, radius * 0.05), weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(palette.quiet)
                }
                Text(centre.time)
                    .font(.system(size: radius * (compact ? 0.17 : 0.15), weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.hand)
                    .contentTransition(still ? .identity : .numericText())
                if let price = centre.price {
                    Text(price)
                        .font(.system(size: max(compact ? 9 : 8, radius * (compact ? 0.1 : 0.085)), weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.hand.opacity(0.85))
                        .contentTransition(still ? .identity : .numericText())
                    if !compact {
                        Text(centre.unit)
                            .font(.system(size: max(7, radius * 0.045)))
                            .foregroundStyle(palette.quiet)
                    }
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: max(7, radius * 0.045)))
                        .foregroundStyle(palette.quiet)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: ring - width * 2)
        }
        .allowsHitTesting(false)
    }
}
