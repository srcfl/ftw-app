import FTWKit
import SwiftUI

/// The plan on Now: the next twelve hours in one strip, on the ground with
/// no card. A header with the price now, the battery's and the car's lanes,
/// the price in eight levels, the hours, and one sentence about what comes
/// next. Its height never depends on what the plan says.
///
/// A tap opens the plan. A drag of 4 pt or more reads the quarters one at a
/// time: the quarter under the finger lights, the sentence gives way to
/// what happens in it, `.selection` ticks per quarter and a light impact
/// marks now, the cheapest hours' edges and the car's goal. On lift the
/// sentence comes back. Only the overlay and the sentence read the finger,
/// so a drag redraws those two and nothing else.
struct PlanStripView: View, Equatable {
    let strip: PlanStrip
    let sentence: String
    /// The box has not answered yet: the sentence is drawn as its shape.
    let placeholder: Bool
    /// "103", the price now. Nil when there is none.
    let priceNow: String?
    /// "ÖRE NU", after the price.
    let priceUnit: String

    @State private var scrub = ScrubModel()
    @State private var width: CGFloat = 0
    @GestureState private var dragging = false
    @ScaledMetric(relativeTo: .caption2) private var kicker: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .subheadline) private var figure: CGFloat = 13

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.strip == b.strip && a.sentence == b.sentence && a.placeholder == b.placeholder && a.priceNow == b.priceNow && a.priceUnit == b.priceUnit
    }

    /// Mono stops growing at accessibility1.
    private var layout: PlanStripLayout { PlanStripLayout(axis: min(axis, 15)) }
    private var mono: Font { .system(size: min(kicker, 15), weight: .medium, design: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ZStack {
                ChartSurface(drawing: PlanStripDrawing(strip: strip, layout: layout))
                    .equatable()
                PlanStripOverlay(strip: strip, model: scrub, layout: layout)
            }
            .frame(height: layout.height)
            StripSentence(sentence: sentence, placeholder: placeholder, grey: strip.grey, readouts: strip.readouts, model: scrub)
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
        .accessibilityValue([sentence, priceNow.map { "\(L("Price now")) \($0) \(priceUnit.lowercased())" }].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(L("Opens the plan."))
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(strip.kicker)
                .font(mono)
                .tracking(0.5)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            if let priceNow {
                Text("\(Text(AppWords.decimal(priceNow)).font(Theme.figure(figure)).foregroundStyle(Theme.ink)) \(Text(priceUnit).font(mono).tracking(0.5).foregroundStyle(Theme.ink2))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.ink3)
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

/// The strip's two reserved lines: the next thing the box will do, or,
/// under a finger, what happens in that quarter. The quarter's line swaps
/// in place with no animation; on lift it goes in 0.1 s and the sentence
/// comes back over 0.2 s.
private struct StripSentence: View {
    let sentence: String
    let placeholder: Bool
    let grey: Bool
    let readouts: [String]
    let model: ScrubModel
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two lines kept, and up to five at the accessibility sizes, where Now
    /// scrolls and keeps no room it does not use.
    private var lines: Int { typeSize.isAccessibilitySize ? 5 : 2 }

    var body: some View {
        let down = model.isDown
        let reading: String = {
            guard case let .slot(i)? = model.shown, readouts.indices.contains(i) else { return " " }
            return readouts[i]
        }()
        ZStack(alignment: .topLeading) {
            Text(sentence)
                .font(.subheadline)
                .foregroundStyle(grey ? Theme.ink3 : Theme.ink2)
                .lineLimit(lines, reservesSpace: !typeSize.isAccessibilitySize)
                // The reason makes the line long; it shrinks a little before
                // it would lose its end.
                .minimumScaleFactor(0.85)
                .redacted(reason: placeholder ? .placeholder : [])
                .opacity(down ? 0 : 1)
                // Back only once the quarter's line has gone, so the two
                // never sit on top of each other.
                .animation(down ? .easeOut(duration: 0.08) : .easeOut(duration: 0.2).delay(0.1), value: down)
                .animation(.easeOut(duration: 0.2), value: sentence)
            Text(reading)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(lines, reservesSpace: !typeSize.isAccessibilitySize)
                .opacity(down ? 1 : 0)
                .animation(.easeOut(duration: down ? 0.08 : 0.1), value: down)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
