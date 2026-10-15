import FTWKit
import SwiftUI

/// The plan on Now: the next twelve hours in one strip, on the ground with
/// no card. A header with the price now, the battery's and the car's lanes,
/// the price in eight levels, the hours, and one sentence about what comes
/// next. Its height never depends on what the plan says; the price row
/// takes the height Now gives it, so on a tall phone the bars read as a
/// chart.
///
/// The price in the header opens the price; a tap anywhere else opens the
/// plan, as the chevron by `NEXT 12 H` says. A drag of 4 pt or more reads
/// the quarters one at a time: the quarter under the finger lights, the
/// header names its time and price, the sentence goes at once and what
/// happens in that quarter fades in, `.selection` ticks per quarter and a
/// light impact marks now, the cheapest hours' edges and the car's goal.
/// On lift the sentence comes back. Only the overlay, the header's price
/// and the sentence read the finger, so a drag redraws those and nothing
/// else.
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
    @GestureState private var dragging = false
    @ScaledMetric(relativeTo: .caption2) private var kicker: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .subheadline) private var figure: CGFloat = 13

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.strip == b.strip && a.sentence == b.sentence && a.shorter == b.shorter && a.placeholder == b.placeholder
            && a.priceNow == b.priceNow && a.unit == b.unit && a.fade == b.fade && a.zoom == b.zoom
    }

    /// Mono stops growing at accessibility1.
    private var layout: PlanStripLayout { PlanStripLayout(axis: min(axis, 15)) }
    private var mono: Font { .system(size: min(kicker, 15), weight: .medium, design: .monospaced) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: HomeRoute.plan) {
                plan
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: HomeRoute.plan, in: zoom)
            .accessibilityIdentifier("now.plan")
            if let priceNow {
                NavigationLink(value: HomeRoute.price) {
                    StripPrice(strip: strip, now: priceNow, unit: unit, model: scrub, figure: figure, mono: mono)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: HomeRoute.price, in: zoom)
                .accessibilityLabel(L("Price now"))
                .accessibilityValue("\(priceNow) \(unit.lowercased())")
                .accessibilityHint(L("Opens the price ahead."))
                .accessibilityIdentifier("now.price")
            }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ZStack {
                ChartSurface(drawing: PlanStripDrawing(strip: strip, layout: layout))
                    .equatable()
                if let fade {
                    MovedFade(fresh: fade.fresh, mask: QuarterColumns(grid: fade.old.grid, quarters: fade.moved)) {
                        ChartSurface(drawing: PlanStripDrawing(strip: fade.old, layout: layout))
                            .equatable()
                    }
                    .id(fade.atMs)
                }
                PlanStripOverlay(strip: strip, model: scrub, layout: layout)
            }
            // The price row takes the height Now gives the strip.
            .frame(minHeight: layout.height, maxHeight: layout.tallest)
            StripSentence(sentence: sentence, shorter: shorter, placeholder: placeholder, grey: strip.grey, readouts: strip.readouts, model: scrub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A tap is the link's; only a finger that moves reads the strip.
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { follow($0.location.x) }
                .onEnded { _ in scrub.lift() }
        )
        // A gesture the system takes away ends without onEnded.
        .onChange(of: dragging) { _, now in if !now { scrub.lift() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PlanGlance.title)
        .accessibilityValue(sentence)
        .accessibilityHint(L("Opens the plan."))
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    /// The kicker and its chevron, and room for the price, which sits over
    /// the strip as a link of its own.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(strip.kicker)
                .font(mono)
                .tracking(0.5)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .contentTransition(.opacity)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 8)
            // The price's line, never drawn: it gives the header the price's
            // height and baseline, so the kicker sits on the same line.
            Text("\(Text(verbatim: "0").font(Theme.figure(figure))) \(Text(verbatim: unit).font(mono).tracking(0.5))")
                .hidden()
        }
        .animation(Theme.spring, value: strip.kicker)
    }

    private func follow(_ x: CGFloat) {
        guard let i = strip.grid.index(atX: x, width: width) else { return }
        scrub.move(to: i, landmark: strip.landmarks.contains(i))
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

/// The strip's two reserved lines: the next thing the box will do, or,
/// under a finger, what happens in that quarter. When the sentence needs a
/// third line at this width, it drops its later clauses rather than end in
/// "…". On touch-down the sentence goes at once and the quarter's line
/// fades in over 0.1 s, so the two never sit on top of each other; on lift
/// the quarter's line goes in 0.1 s and the sentence comes back over 0.2 s.
private struct StripSentence: View {
    let sentence: String
    let shorter: [String]
    let placeholder: Bool
    let grey: Bool
    let readouts: [String]
    let model: ScrubModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let down = model.isDown
        let reading: String = {
            guard case let .slot(i)? = model.shown, readouts.indices.contains(i) else { return " " }
            return readouts[i]
        }()
        ZStack(alignment: .topLeading) {
            said
                .foregroundStyle(grey ? Theme.ink3 : Theme.ink2)
                .redacted(reason: placeholder ? .placeholder : [])
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
                    ViewThatFits(in: .vertical) {
                        ForEach([sentence] + shorter, id: \.self) { form in
                            Text(form).font(.subheadline)
                        }
                    }
                }
        }
    }
}
