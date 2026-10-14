import FTWKit
import SwiftUI

/// The planning style as one control with five stops, very careful at the
/// left and very bold at the right. A finger moves the thumb from stop to
/// stop with a `.selection` tick at each; the style's name and help under
/// it follow the thumb; one command goes on release, and only when the stop
/// changed. The status line carries the receipt.
///
/// Drawn from the cache it shows the box's style and rests until the box
/// has spoken; before the box has said a style it has no thumb. It rests
/// too while a manual mode runs and while a change is on its way.
/// VoiceOver steps it a style at a time, reading the name and the help,
/// and each step goes to the box. With Reduce Motion the thumb jumps.
///
/// Two shapes share the logic: a straight scale, used, and a short arc in
/// the dial's ticks (`-FTWStyleControl arc`), kept to compare the two.
struct StyleScale: View {
    let mode: ModeModel
    /// "New plan 16:53: …", after a change, until the next plan.
    var moved: String?
    var look: Look = .chosen
    #if DEBUG
    /// With `-FTWStyleScrub YES`, this scale moves itself a few stops and
    /// lets go, for recordings. `reveal` scrolls it into view first, and
    /// back to the plan after.
    var drives = false
    var reveal: ((Bool) -> Void)?
    #endif

    enum Look: String {
        case line, arc

        static var chosen: Look {
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "FTWStyleControl"), let look = Look(rawValue: raw) { return look }
            #endif
            return .line
        }
    }

    /// The stop under the finger.
    @State private var held: Int?
    /// The stop let go on, until the box has answered.
    @State private var asked: Int?
    @State private var size: CGSize = .zero
    @GestureState private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var kicker: CGFloat = 10.5

    private static let styles = ModeModel.styles
    private static let thumb: CGFloat = 28

    /// The box's style, or the one asked for while it is on its way.
    private var boxStop: Int? { mode.shownStyle.flatMap { s in Self.styles.firstIndex(of: s) } }
    private var stop: Int? { held ?? asked ?? boxStop }

    /// A change can go: the box has spoken, the plan runs, and nothing else
    /// is on its way.
    private var live: Bool {
        mode.canControl && mode.connected && !mode.sending && mode.prefs != nil && ModeWords.isPlan(mode.shown ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            // Its own element, so VoiceOver reads what moved.
            if let moved {
                Text(moved)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("style.moved")
            }
        }
        .animation(.easeOut(duration: 0.2), value: moved)
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            ends
            track
                .frame(height: look == .line ? 32 : 84)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .contentShape(Rectangle())
                .gesture(drag, isEnabled: live)
                .onChange(of: dragging) { _, now in if !now { release() } }
            caption
        }
        .opacity(live || mode.sending ? 1 : 0.55)
        .sensoryFeedback(trigger: held) { old, new in
            guard let new, new != (old ?? boxStop) else { return nil }
            return .selection
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Planning style"))
        .accessibilityValue(stop.map { "\(L(Self.styles[$0].name)). \(L(Self.styles[$0].help))" } ?? "")
        .accessibilityHint(live ? L("Swipe up or down to change the style.") : "")
        .accessibilityAdjustableAction { direction in
            guard live, let from = stop else { return }
            let to = direction == .increment ? from + 1 : from - 1
            guard Self.styles.indices.contains(to) else { return }
            send(to)
        }
        .accessibilityIdentifier("style.scale")
        #if DEBUG
        .task { await drive() }
        #endif
    }

    /// "CAREFUL" at one end and "BOLD" at the other, in the kickers' mono.
    private var ends: some View {
        HStack {
            Text(verbatim: "← \(L("Careful").uppercased())")
            Spacer(minLength: 8)
            Text(verbatim: "\(L("Bold").uppercased()) →")
        }
        .font(.system(size: min(kicker, 15), weight: .medium, design: .monospaced))
        .tracking(0.5)
        .foregroundStyle(Theme.ink3)
        .lineLimit(1)
    }

    private var track: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(&context, size)
            }
            if let stop, size.width > 0 {
                let p = point(Self.styles.count == 1 ? 0.5 : ModeModel.fraction(of: stop), in: size)
                Circle()
                    .fill(Theme.ink)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .position(p)
                    .animation(reduceMotion ? nil : Theme.spring, value: stop)
                    .transition(.opacity)
            }
        }
    }

    /// The groove and its five stops; the stop the thumb is on is ink.
    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let n = Self.styles.count
        var groove = Path()
        switch look {
        case .line:
            groove.move(to: point(0, in: size))
            groove.addLine(to: point(1, in: size))
        case .arc:
            groove.move(to: point(0, in: size))
            for i in 1...40 { groove.addLine(to: point(Double(i) / 40, in: size)) }
        }
        context.stroke(groove, with: .color(Theme.ink3.opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        for i in 0..<n {
            let f = ModeModel.fraction(of: i)
            let colour = i == stop ? Theme.ink : Theme.ink3
            switch look {
            case .line:
                let p = point(f, in: size)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(colour))
            case .arc:
                // A tick across the arc, as the dial draws its quarters.
                let (inner, outer) = (point(f, in: size, radius: -9), point(f, in: size, radius: 9))
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                context.stroke(tick, with: .color(colour), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// The style's name and its help in one line, which change as the thumb
    /// moves. The room they take is the largest of the five, so nothing
    /// below moves. VoiceOver reads the whole help.
    private var caption: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.styles) { s in describe(s).hidden() }
            if let stop {
                describe(Self.styles[stop])
                    .id(stop)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: stop)
    }

    private func describe(_ s: ModeModel.Style) -> some View {
        Text("\(Text(L(s.name)).fontWeight(.semibold).foregroundStyle(Theme.ink)) · \(Text(L(s.brief)).foregroundStyle(Theme.ink2))")
            .font(.subheadline)
            .foregroundStyle(Theme.ink2)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The finger

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { held = ModeModel.stop(at: fraction(at: $0.location)) }
            .onEnded { _ in release() }
    }

    /// One command, on release, when the stop changed.
    private func release() {
        guard let h = held else { return }
        held = nil
        guard h != boxStop else { return }
        send(h)
    }

    private func send(_ i: Int) {
        asked = i
        Task {
            await mode.setStyle(Self.styles[i])
            asked = nil
        }
    }

    // MARK: Where things sit

    /// The arc spans this far either side of its top, in radians.
    private static let sweep = 0.62

    /// A place along the scale, 0 to 1, as a point in the track. `radius`
    /// moves it across the arc, outward when positive.
    private func point(_ f: Double, in size: CGSize, radius: CGFloat = 0) -> CGPoint {
        let inset = Self.thumb / 2 + 2
        switch look {
        case .line:
            return CGPoint(x: inset + (size.width - 2 * inset) * f, y: size.height / 2)
        case .arc:
            let (centre, r) = arc(size)
            let a = -Self.sweep + 2 * Self.sweep * f
            return CGPoint(x: centre.x + (r + radius) * sin(a), y: centre.y - (r + radius) * cos(a))
        }
    }

    /// The place along the scale nearest a point.
    private func fraction(at p: CGPoint) -> Double {
        let inset = Self.thumb / 2 + 2
        switch look {
        case .line:
            guard size.width > 2 * inset else { return 0.5 }
            return min(1, max(0, (p.x - inset) / (size.width - 2 * inset)))
        case .arc:
            let (centre, _) = arc(size)
            let a = atan2(p.x - centre.x, centre.y - p.y)
            return min(1, max(0, (a + Self.sweep) / (2 * Self.sweep)))
        }
    }

    /// The arc's centre and radius: its ends meet the track's sides and its
    /// top touches the track's top.
    private func arc(_ size: CGSize) -> (CGPoint, CGFloat) {
        let inset = Self.thumb / 2 + 2
        let r = (size.width / 2 - inset) / sin(Self.sweep)
        return (CGPoint(x: size.width / 2, y: inset + r), r)
    }

    #if DEBUG
    private func drive() async {
        guard drives, UserDefaults.standard.bool(forKey: "FTWStyleScrub") else { return }
        while !live {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .seconds(1.5))
        for path in [[3, 4], [3, 2, 1], [2]] {
            reveal?(true)
            try? await Task.sleep(for: .seconds(1.2))
            for s in path {
                held = s
                try? await Task.sleep(for: .milliseconds(450))
            }
            release()
            // Back to the dial before the box's new plan lands, so its
            // moved quarters fade in view.
            try? await Task.sleep(for: .milliseconds(250))
            reveal?(false)
            try? await Task.sleep(for: .seconds(4))
            while !live {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
        }
    }
    #endif
}
