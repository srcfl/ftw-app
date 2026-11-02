import FTWKit
import SwiftUI

/// The plan on Now: the next twelve hours in one strip, on the ground with
/// no card. A header with the price now, the battery's and the car's lanes,
/// the price from zero with its scale, the hours, and one sentence about
/// what comes next. Its height never depends on what the plan says; the price row
/// takes the height Now gives it, so on a tall phone the bars read as a
/// chart.
///
/// Under the strip, the three figures of one pass (proposal 5, picked by
/// Fredrik on 1 Nov 2026): the battery's run under way or next, until a
/// tap on another run or car window chooses it. The chosen pass is drawn
/// in full colour with the bars under it in its colour.
///
/// The price in the header opens the price; a tap on a pass chooses it; a
/// tap anywhere else opens the plan, as the chevron by `NEXT 12 H` says. A drag of 4 pt or more reads
/// the quarters one at a time: the quarter under the finger lights, the
/// header names its time and price, the sentence goes at once and what
/// happens in that quarter fades in, `.selection` ticks per quarter and a
/// light impact marks now, the cheapest hours' edges and the car's goal.
/// On lift the sentence comes back. Only the overlay, the header's price
/// and the sentence read the finger, so a drag redraws those and nothing
/// else.
///
/// In the plan the strip sits in the page's scroll and has no gesture of
/// its own: any there held the page still for every swipe that started on
/// it. The page hands it each touch (`DialTouch`), and it scrubs once the
/// finger moves mostly sideways or rests 0.1 s (`LaneIntent`), as the
/// lanes did; up or down scrolls the page, which holds still while the
/// strip scrubs.
struct PlanStripView: View, Equatable {
    let strip: PlanStrip
    let sentence: String
    /// The sentence one clause shorter each, for a width with no room for
    /// it in two lines.
    var shorter: [String] = []
    /// The box has not answered yet: the sentence is drawn as its shape.
    let placeholder: Bool
    /// "103", the price now in whole öre. Nil when there is none.
    let priceNow: String?
    /// "ÖRE", after a price.
    let unit: String
    /// The strip before the person's last change, while its plan stands.
    var fade: StripFade?
    /// The zooms into the plan and the price grow out of this strip.
    let zoom: Namespace.ID

    @State private var scrub = ScrubModel()
    @State private var width: CGFloat = 0
    /// The pass a tap chose, by id, so it holds while the plan stands. The
    /// plan view shares it with its dial.
    @Binding var chosenID: String?
    /// On Now the strip opens the plan; in the plan it is the plan.
    var opensPlan = true
    /// The battery level's row: none on Now, room for it in the lanes.
    var levelHeight: CGFloat = 0
    /// The least the price row takes: Now gives it what room it has; the
    /// plan, which scrolls, asks for more.
    var leastPrice: CGFloat = PlanStripLayout.leastPrice
    /// Which price the bars are, "SPOT EXCL. VAT", after the kicker.
    var priceLabel: String?
    /// In the plan, the page's touches, handed on.
    var touch: DialTouch?
    /// True while a finger scrubs the strip in the plan: the page holds
    /// still.
    var holds: Binding<Bool>?
    /// The battery's level now, read by the figures alone, so a run under
    /// way says where it starts from without the strip redrawing.
    var site: SiteModel?
    /// Where the strip's drawing sits, for the passes' tap targets.
    @State private var canvas: CGRect = .zero
    @State private var finger = StripFinger()
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var dragging = false
    @ScaledMetric(relativeTo: .caption2) private var kicker: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .subheadline) private var figure: CGFloat = 13

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.strip == b.strip && a.sentence == b.sentence && a.shorter == b.shorter && a.placeholder == b.placeholder
            && a.priceNow == b.priceNow && a.unit == b.unit && a.fade == b.fade && a.zoom == b.zoom
            && a.chosenID == b.chosenID && a.opensPlan == b.opensPlan && a.levelHeight == b.levelHeight && a.leastPrice == b.leastPrice
            && a.priceLabel == b.priceLabel && a.touch === b.touch && a.site === b.site
    }

    /// Mono stops growing at accessibility1.
    private var layout: PlanStripLayout { PlanStripLayout(axis: min(axis, 15), levelHeight: levelHeight) }
    private var mono: Font { .system(size: min(kicker, 15), weight: .medium, design: .monospaced) }

    /// The pass the figures show: the one a tap chose while the plan still
    /// has it, else the one the strip opens on.
    private var chosen: PlanPass? {
        strip.passes.first { $0.id == chosenID } ?? PlanPass.opening(strip.passes)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if opensPlan {
                NavigationLink(value: HomeRoute.plan) {
                    plan
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: HomeRoute.plan, in: zoom)
                .accessibilityIdentifier("now.plan")
            } else {
                plan
            }
            if let priceNow {
                NavigationLink(value: HomeRoute.price(nil)) {
                    StripPrice(strip: strip, now: priceNow, unit: unit, model: scrub, figure: figure, mono: mono)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: HomeRoute.price(nil), in: zoom)
                .accessibilityLabel(L("Price now"))
                .accessibilityValue("\(priceNow) \(unit.lowercased())")
                .accessibilityHint(L("Opens the price ahead."))
                .accessibilityIdentifier("now.price")
            }
        }
        .overlay(alignment: .topLeading) {
            PassTargets(strip: strip, layout: layout, chosenID: $chosenID)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .offset(x: canvas.minX, y: canvas.minY)
        }
        .coordinateSpace(.named(Self.space))
        .sensoryFeedback(.selection, trigger: chosenID)
    }

    private static let space = "now.strip"

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ZStack {
                ChartSurface(drawing: PlanStripDrawing(strip: strip, layout: layout, chosen: chosen))
                    .equatable()
                if let fade {
                    MovedFade(fresh: fade.fresh, mask: QuarterColumns(grid: fade.old.grid, quarters: fade.moved, trailing: layout.gutter)) {
                        ChartSurface(drawing: PlanStripDrawing(strip: fade.old, layout: layout, chosen: fade.old.passes.first { $0.id == chosen?.id }))
                            .equatable()
                    }
                    .id(fade.atMs)
                }
                PlanStripOverlay(strip: strip, model: scrub, layout: layout)
            }
            // The price row takes the height Now gives the strip.
            .frame(minHeight: layout.height + max(0, leastPrice - PlanStripLayout.leastPrice), maxHeight: layout.tallest)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { canvas = $0 }
            // Where the drawing is on the screen, for the page's touches:
            // written to a plain reference, so a scroll redraws nothing.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { finger.frame = $0 }
            StripSentence(sentence: sentence, shorter: shorter, placeholder: placeholder, grey: strip.grey, pass: chosen, readouts: strip.readouts, model: scrub, site: site)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A tap is the link's; only a finger that moves reads the strip. In
        // the plan's scroll the page's touches read it instead.
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { follow($0.location.x) }
                .onEnded { _ in scrub.lift() },
            including: opensPlan ? .all : .subviews
        )
        // A gesture the system takes away ends without onEnded.
        .onChange(of: dragging) { _, now in if !now { scrub.lift() } }
        .onChange(of: strip, initial: true) { _, now in finger.strip = now }
        .onChange(of: layout, initial: true) { _, now in finger.layout = now }
        .onAppear {
            touch?.take(finger, changed: { value in
                // A new touch has a new start; one the system took away
                // never ended.
                if finger.startAt != value.startLocation {
                    touchEnded()
                    touchStarted(value)
                }
                touchMoved(value)
            }, ended: { touchEnded() })
        }
        .onDisappear {
            touch?.release(finger)
            touchEnded()
        }
        // A touch the system took (a call, Control Center, a switch of
        // app) may never end: the page is not left held.
        .onChange(of: scenePhase) { _, phase in if phase != .active { touchEnded() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PlanGlance.title)
        .accessibilityValue(sentence)
        .accessibilityHint(opensPlan ? L("Opens the plan.") : "")
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    /// The kicker and its chevron, and room for the price, which sits over
    /// the strip as a link of its own. Beside the price where both fit; at
    /// the largest sizes the price takes the first line and the kicker the
    /// next, so the two never overlap.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                kickerLine
                Spacer(minLength: 8)
                priceRoom
            }
            VStack(alignment: .leading, spacing: 4) {
                priceRoom
                kickerLine
            }
        }
        .animation(Theme.spring, value: strip.kicker)
    }

    private var kickerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(priceLabel.map { strip.kicker + " · " + $0 } ?? strip.kicker)
                .font(mono)
                .tracking(0.5)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.opacity)
            if opensPlan {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    /// The price's line, never drawn: it gives the header the price's
    /// width, height and baseline, so the kicker sits on the same line and
    /// clear of it.
    private var priceRoom: some View {
        let figures = priceNow.map { AppWords.decimal($0) } ?? "0"
        let words = priceNow == nil ? unit : "\(unit) \(PlanGlance.nowWord)"
        return Text("\(Text(verbatim: figures).font(Theme.figure(figure))) \(Text(verbatim: words).font(mono).tracking(0.5))")
            .lineLimit(1)
            .hidden()
    }

    private func follow(_ x: CGFloat) {
        guard let i = strip.grid.index(atX: x, width: layout.plotWidth(width)) else { return }
        scrub.move(to: i, landmark: strip.landmarks.contains(i))
    }

    // MARK: The page's touches, in the plan

    /// A finger came down somewhere on the page. The strip takes it only
    /// on its drawing, and never within 20 pt of the screen's leading
    /// edge, where the back swipe starts.
    private func touchStarted(_ v: DragGesture.Value) {
        finger.startAt = v.startLocation
        finger.startMs = ProcessInfo.processInfo.systemUptime * 1000
        finger.decision = nil
        let plot = CGRect(x: finger.frame.minX, y: finger.frame.minY, width: finger.layout.plotWidth(finger.frame.width), height: finger.frame.height)
        guard v.startLocation.x >= EdgeRule.edge, plot.insetBy(dx: 0, dy: -8).contains(v.startLocation) else {
            finger.decision = .pass
            return
        }
        finger.hold = Task {
            try? await Task.sleep(for: .milliseconds(Int(RingIntent.holdMs)))
            guard !Task.isCancelled, finger.decision == nil else { return }
            touchDecided(.scrub)
        }
    }

    /// Each event costs a little arithmetic and writes nothing a view
    /// reads, until the touch is a scrub.
    private func touchMoved(_ v: DragGesture.Value) {
        finger.last = v.location
        guard finger.decision == nil else {
            if finger.decision == .scrub { touchFollow(v.location) }
            return
        }
        let held = ProcessInfo.processInfo.systemUptime * 1000 - (finger.startMs ?? 0)
        if let decision = LaneIntent.decide(start: v.startLocation, now: v.location, heldMs: held) {
            touchDecided(decision)
        }
    }

    private func touchDecided(_ decision: RingIntent.Decision) {
        finger.decision = decision
        finger.hold?.cancel()
        guard decision == .scrub else { return }
        holds?.wrappedValue = true
        if let at = finger.last { touchFollow(at) }
    }

    /// The quarter under the finger, clamped to the strip.
    private func touchFollow(_ p: CGPoint) {
        guard let strip = finger.strip else { return }
        let w = finger.layout.plotWidth(finger.frame.width)
        guard w > 0 else { return }
        let x = min(max(p.x - finger.frame.minX, 0), w - 0.5)
        guard let i = strip.grid.index(atX: x, width: w), i != scrub.index else { return }
        scrub.move(to: i, landmark: strip.landmarks.contains(i))
    }

    private func touchEnded() {
        guard finger.startMs != nil else { return }
        finger.hold?.cancel()
        finger.hold = nil
        finger.startAt = nil
        finger.startMs = nil
        finger.decision = nil
        finger.last = nil
        if holds?.wrappedValue == true { holds?.wrappedValue = false }
        if scrub.isDown { scrub.lift() }
    }

    #if DEBUG
    /// With `-FTWStripScrub YES`, a thumb sweeps the strip back and forth
    /// for ten seconds through the same path a finger takes, for recordings
    /// and frame measurements where nothing can touch.
    private func autoScrub() async {
        guard UserDefaults.standard.bool(forKey: "FTWStripScrub") else { return }
        try? await Task.sleep(for: .seconds(2))
        let began = ContinuousClock.now
        while ContinuousClock.now - began < .seconds(10) {
            let t = (ContinuousClock.now - began) / .milliseconds(2_400)
            let phase = t.truncatingRemainder(dividingBy: 2)
            follow(CGFloat(phase < 1 ? phase : 2 - phase) * width)
            try? await Task.sleep(for: .milliseconds(8))
        }
        scrub.lift()
    }
    #endif
}

/// A finger on the strip in the plan, and where the strip sits: a plain
/// reference, so a touch or a scroll writes nothing a view reads.
@MainActor
private final class StripFinger {
    /// Where and when the touch came down, on the screen.
    var startAt: CGPoint?
    var startMs: Double?
    var decision: RingIntent.Decision?
    var last: CGPoint?
    var hold: Task<Void, Never>?
    /// The drawing, on the screen.
    var frame: CGRect = .zero
    /// The strip and its layout on screen: the page's handler outlives a
    /// minute's strip.
    var strip: PlanStrip?
    var layout = PlanStripLayout()
}

/// The header's price: now, `156 ÖRE NOW`, and under a finger the
/// quarter's, `10:00 · 87 ÖRE`, in whole öre as the quarter's line says it.
/// It swaps in place with the quarter, with no animation.
private struct StripPrice: View {
    let strip: PlanStrip
    let now: String
    let unit: String
    let model: ScrubModel
    let figure: CGFloat
    let mono: Font

    var body: some View {
        let quarter = model.index.flatMap { strip.quarters.indices.contains($0) ? strip.quarters[$0] : nil }
        Group {
            if let quarter {
                Text("\(Text(verbatim: "\(quarter.time) · ").font(mono).tracking(0.5).foregroundStyle(Theme.ink2))\(Text(verbatim: AppWords.decimal(quarter.price ?? "—")).font(Theme.figure(figure)).foregroundStyle(Theme.ink)) \(Text(verbatim: unit).font(mono).tracking(0.5).foregroundStyle(Theme.ink2))")
            } else {
                Text("\(Text(verbatim: AppWords.decimal(now)).font(Theme.figure(figure)).foregroundStyle(Theme.ink)) \(Text(verbatim: "\(unit) \(PlanGlance.nowWord)").font(mono).tracking(0.5).foregroundStyle(Theme.ink2))")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // The price now rolls when its quarter turns; a finger's quarter
        // swaps outside any animation.
        .contentTransition(.numericText())
        .animation(Theme.spring, value: now)
    }
}

/// Under the strip: the chosen pass's figures, or with no pass the next
/// thing the box will do in two reserved lines; under a finger, what
/// happens in that quarter. When the sentence needs a
/// third line at this width, it drops its later clauses rather than end in
/// "…". On touch-down the sentence goes at once and the quarter's line
/// fades in over 0.1 s, so the two never sit on top of each other; on lift
/// the quarter's line goes in 0.1 s and the sentence comes back over 0.2 s.
private struct StripSentence: View {
    let sentence: String
    let shorter: [String]
    let placeholder: Bool
    let grey: Bool
    let pass: PlanPass?
    let readouts: [String]
    let model: ScrubModel
    let site: SiteModel?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let down = model.isDown
        let reading: String = {
            guard case let .slot(i)? = model.shown, readouts.indices.contains(i) else { return " " }
            return readouts[i]
        }()
        ZStack(alignment: .topLeading) {
            Group {
                if let pass, !placeholder {
                    LevelNowFigures(pass: pass, grey: grey, site: site)
                } else {
                    said
                        .foregroundStyle(grey ? Theme.ink3 : Theme.ink2)
                        .redacted(reason: placeholder ? .placeholder : [])
                }
            }
                .opacity(down ? 0 : 1)
                // Back only once the quarter's line has gone.
                .animation(down ? nil : .easeOut(duration: 0.2).delay(0.1), value: down)
                .animation(.easeOut(duration: 0.2), value: sentence)
            Text(reading)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(lines, reservesSpace: !typeSize.isAccessibilitySize)
                .opacity(down ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: down)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Two lines kept, and up to five at the accessibility sizes, where Now
    /// scrolls and keeps no room it does not use.
    private var lines: Int { typeSize.isAccessibilitySize ? 5 : 2 }

    /// The longest form of the sentence that fits its two lines.
    @ViewBuilder private var said: some View {
        if typeSize.isAccessibilitySize {
            Text(sentence).font(.subheadline)
        } else {
            Text(verbatim: " ")
                .font(.subheadline)
                .lineLimit(lines, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    // By place, never by the words: a shorter form that
                    // equals the sentence would give two candidates one
                    // id, which `ViewThatFits` refuses.
                    ViewThatFits(in: .vertical) {
                        ForEach(Array(([sentence] + shorter).enumerated()), id: \.offset) { _, form in
                            Text(form).font(.subheadline)
                        }
                    }
                }
        }
    }
}

/// A tap target over each pass on the strip's lanes, as wide as its run and
/// at least 28 pt, from just above the battery's lane to the top of the
/// bars. Where a battery run and a car window share the same minutes, each
/// takes its own lane's half. A tap chooses the pass; VoiceOver reads each
/// as a button that says the pass.
private struct PassTargets: View {
    let strip: PlanStrip
    let layout: PlanStripLayout
    @Binding var chosenID: String?

    var body: some View {
        GeometryReader { geo in
            let width = layout.plotWidth(geo.size.width)
            ForEach(strip.passes) { pass in
                let r = rect(pass, width: width)
                Button {
                    chosenID = pass.id
                } label: {
                    Color.clear
                        .frame(width: r.width, height: r.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: r.midX, y: r.midY)
                .accessibilityLabel(pass.spoken)
                .accessibilityAddTraits(pass.id == (strip.passes.first { $0.id == chosenID } ?? PlanPass.opening(strip.passes))?.id ? .isSelected : [])
            }
        }
    }

    private func rect(_ pass: PlanPass, width: CGFloat) -> CGRect {
        let x0 = strip.grid.x(atMs: strip.grid.startMs(pass.first), width: width)
        let x1 = strip.grid.x(atMs: strip.grid.endMs(pass.last), width: width)
        let w = max(28, x1 - x0)
        let x = min(max(0, (x0 + x1) / 2 - w / 2), max(0, width - w))
        let shared = strip.passes.contains { $0.isBattery != pass.isBattery && $0.first <= pass.last && $0.last >= pass.first }
        let split = PlanStripLayout.carY - 2
        let top: CGFloat = -8, bottom = PlanStripLayout.lanesBottom
        let y0 = shared && !pass.isBattery ? split : top
        let y1 = shared && pass.isBattery ? split : bottom
        return CGRect(x: x, y: y0, width: w, height: y1 - y0)
    }
}
