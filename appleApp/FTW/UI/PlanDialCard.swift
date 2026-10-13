import FTWKit
import SwiftUI

/// The plan dial at the top of the plan view. A finger dragged round it
/// scrubs the plan a quarter at a time, onto tomorrow past midnight and
/// back; the line under it says what is planned there and springs back to
/// the plan's own sentence when the finger lifts. VoiceOver steps it an
/// hour at a time.
struct PlanDialCard: View {
    let entry: PlanEntry
    /// The minute: the dial marks it, not the second.
    let nowMs: Double
    let batteryPct: Double?
    /// The battery's reading is not live.
    let batteryOld: Bool
    /// Prices are on their way from the box.
    let fetching: Bool
    /// The line under the dial while no finger is on it.
    let summary: String

    @State private var face: PlanDial.Face?
    @State private var size: CGSize = .zero
    /// The finger, in turns along the spiral, and the quarter under it.
    @State private var progress: Double?
    @State private var selected: Int?
    /// Where VoiceOver has stepped to.
    @State private var spoken: Int?
    @State private var ticks = 0
    @State private var bumps = 0
    @State private var lastTick = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let face = self.face ?? PlanDial.face(entry, nowMs: nowMs)
        let marked = selected ?? spoken
        VStack(alignment: .leading, spacing: 8) {
            PlanDialView(
                face: face,
                nowMs: nowMs,
                palette: .app,
                batteryPct: batteryPct,
                batteryOld: batteryOld,
                selected: marked,
                still: reduceMotion || PowerState.shared.lowPower,
                fetching: fetching,
                note: note(face)
            )
            // The dial carries its own dark glass in both schemes.
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 380)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .contentShape(DialRing(), eoFill: true)
            .gesture(scrub(face))
            .accessibilityLabel(L("Plan dial"))
            .accessibilityValue(spokenValue(face, at: spoken))
            .accessibilityHint(L("Swipe up or down to move an hour."))
            .accessibilityAdjustableAction { step(face, $0) }
            .accessibilityIdentifier("plan.dial")
            ReadoutLine(readout: marked.flatMap { Readouts.dial(face, $0, nowMs: nowMs) }, otherwise: summary)
                .accessibilityHidden(marked != nil)
            DialLegend(car: face.quarters.contains(where: \.car))
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: bumps)
        .onChange(of: FaceKey(entry: entry, quarter: Int(nowMs / PlanDial.quarterMs)), initial: true) {
            self.face = PlanDial.face(entry, nowMs: nowMs)
        }
    }

    /// The prices for tomorrow: on their way, or when they come.
    private func note(_ face: PlanDial.Face) -> String? {
        if fetching, !face.tomorrowPriced { return L("fetching…") }
        return PlanDial.tomorrowNote(face, nowMs: nowMs)
    }

    // MARK: A finger

    private func scrub(_ face: PlanDial.Face) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let reach = face.reach, size.width > 0 else { return }
                let radius = min(size.width, size.height) / 2 / 1.14
                let x = (drag.location.x - size.width / 2) / radius
                let y = (drag.location.y - size.height / 2) / radius
                // Past either end the finger winds no further, so turning
                // back answers at once.
                let lo = face.quarters[reach.lowerBound].progress, hi = face.quarters[reach.upperBound].progress
                let p = min(hi + 0.01, max(lo - 0.01, PlanDial.progress(x: x, y: y, from: progress)))
                progress = p
                guard let i = face.index(atProgress: p), i != selected else { return }
                selected = i
                if i == face.index(at: nowMs) || face.edgesCheapest(i) {
                    bumps += 1
                } else if Date().timeIntervalSince(lastTick) >= 0.04 {
                    lastTick = Date()
                    ticks += 1
                }
            }
            .onEnded { _ in
                progress = nil
                selected = nil
            }
    }

    // MARK: VoiceOver

    /// An hour a step, from now to the end of the prices and back to
    /// midnight.
    private func step(_ face: PlanDial.Face, _ direction: AccessibilityAdjustmentDirection) {
        let forward: Bool
        switch direction {
        case .increment: forward = true
        case .decrement: forward = false
        @unknown default: return
        }
        spoken = face.step(from: spoken, forward: forward, nowMs: nowMs) ?? spoken
    }

    /// "14:00–14:15, battery stores · spare solar · 65,5 öre/kWh", and the
    /// battery's level at now.
    private func spokenValue(_ face: PlanDial.Face, at index: Int?) -> String {
        let i = index ?? face.index(at: nowMs)
        guard let i, let readout = Readouts.dial(face, i, nowMs: nowMs) else { return summary }
        var text = "\(readout.when), \(readout.what)"
        if i == face.index(at: nowMs), let batteryPct {
            text = "\(L("now")), \(text), \(NodeWords.format("battery %@", PlanDial.percent(batteryPct)))"
        }
        return text
    }
}

/// What makes the face out of date: the plan, and the quarter, since the
/// cheapest stretch is reckoned from now.
private struct FaceKey: Equatable {
    let entry: PlanEntry
    let quarter: Int
}

/// Where a finger scrubs: the spiral and its rim, not the middle, so a
/// drag that starts on the battery's ring scrolls the page.
private struct DialRing: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let inner = side / 2 / 1.14 * (PlanDial.Layout.battery + PlanDial.Layout.batteryWidth)
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        path.addEllipse(in: CGRect(x: rect.midX - inner, y: rect.midY - inner, width: inner * 2, height: inner * 2))
        return path
    }
}

/// What each mark on the dial means.
private struct DialLegend: View {
    let car: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
        .font(.caption2)
        .foregroundStyle(Theme.fgDim)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var items: some View {
        item(.store, L("stores"))
        item(.use, L("used"))
        item(.wait, L("waits"))
        if car { item(.car, L("car charges")) }
    }

    private func item(_ mark: DialSwatch.Mark, _ text: String) -> some View {
        HStack(spacing: 5) {
            DialSwatch(mark: mark)
            Text(text).lineLimit(1)
        }
    }
}

/// A mark as the dial draws it, on a dot of its dark glass, so white reads
/// as white on a light page too.
struct DialSwatch: View {
    enum Mark { case store, use, wait, car, cheap }
    let mark: Mark

    init(mark: Mark) { self.mark = mark }

    /// A plan event's mark: the battery's runs as on the dial.
    init(kind: PlanGlance.Kind) {
        switch kind {
        case .charge: mark = .store
        case .discharge: mark = .use
        case .car: mark = .car
        case .cheap: mark = .cheap
        }
    }

    var body: some View {
        Group {
            switch mark {
            case .store: bar(Theme.storage)
            case .use: bar(Theme.fg)
            case .wait: bar(Theme.fgMuted)
            case .cheap: bar(Theme.exporting)
            case .car: Circle().fill(Theme.mobility).frame(width: 4, height: 4)
            }
        }
        .frame(width: 14, height: 14)
        .background(Theme.surface.opacity(0.92), in: Circle())
        .environment(\.colorScheme, .dark)
    }

    private func bar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 8)
    }
}

extension PlanDialPalette {
    /// The app's tokens. The dial sets the dark scheme on itself, so they
    /// resolve as they read on its dark glass: cyan stores, white is used,
    /// grey waits, gold is the sun.
    static let app = PlanDialPalette(
        store: Theme.storage,
        use: Theme.fg,
        wait: Theme.fgMuted,
        car: Theme.mobility,
        sun: Theme.generation,
        hand: Theme.fg,
        battery: Theme.storage,
        quiet: Theme.fgDim,
        glass: Theme.surface
    )
}
