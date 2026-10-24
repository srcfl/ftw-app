import FTWKit
import SwiftUI

extension View {
    /// The bar of a home's screens: the title with the status line under
    /// it, both at the leading edge in every frame, in the system's own
    /// bar, so the line never scrolls away and needs no band of its own. A
    /// tap on the line opens the control sheet.
    func homeBar<Title: View>(app: AppModel, home: HomeModels, @ViewBuilder title: () -> Title) -> some View {
        modifier(HomeBar(app: app, home: home, title: title()))
    }

    /// A screen's bar: its name over the status line. `id` names the title
    /// for the UI tests.
    func homeBar(app: AppModel, home: HomeModels, title: String, id: String = "bar.title") -> some View {
        homeBar(app: app, home: home) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
        }
    }
}

private struct HomeBar<Title: View>: ViewModifier {
    let app: AppModel
    let home: HomeModels
    let title: Title
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                // One item as wide as the bar allows, its lines at the
                // leading edge. The bar centres a title that fits and moves
                // one that does not to the edge, so a title as wide as its
                // words jumped each time the line or the mode button changed
                // width.
                ToolbarItem(placement: .title) {
                    VStack(alignment: .leading, spacing: 1) {
                        title
                        StatusLineButton(app: app, home: home) { open = true }
                    }
                    .frame(minWidth: 0, idealWidth: Self.wide, maxWidth: .infinity, alignment: .leading)
                    // Chrome in the bar: whole words before large letters.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
            }
            .sheet(isPresented: $open) {
                ControlSheet(app: app, home: home)
            }
            #if DEBUG
            // For screenshots: `-FTWSheet control` opens the control sheet.
            .task {
                if UserDefaults.standard.string(forKey: "FTWSheet") == "control" { open = true }
            }
            #endif
    }

    /// Wider than any bar, so the bar gives the item all the room it has
    /// from the first frame on.
    static var wide: CGFloat { 2_000 }
}

/// The line itself, in its own view so a reading redraws this line and not
/// the screen under it. It reads the clock only to know whether a
/// receipt still holds; nothing on it counts.
private struct StatusLineButton: View {
    let app: AppModel
    let home: HomeModels
    let tap: () -> Void

    var body: some View {
        let site = home.site
        let mode = home.nodes.mode
        let line = StatusLine.make(StatusLine.facts(
            site: site,
            mode: mode,
            demo: app.isDemo,
            online: NetworkState.shared.online,
            noCarrier: app.connectHelp != nil,
            receipt: StatusLine.receipt(mode, nowMs: site.nowMs)
        ))
        Button(action: tap) {
            StatusLineView(line: line)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Status"))
        .accessibilityValue(line.text)
        .accessibilityHint(L("Shows whether FTW is in control, and how it knows."))
        .accessibilityIdentifier("status.line")
    }
}

/// `● LIVE · FTW IN CONTROL` in the terminal's mono. The dot is lit lime
/// only while live, with a small glow in dark mode; anything else is a
/// hollow ring. Each part keeps its place while it stays: on a receipt
/// `DEMO` and `SENT ▸` hold still and only the new step fades in, and the
/// old one goes at once, so two words never sit on top of each other and
/// the line is never blank. When the dot changes, every part is new. A
/// line too long for the bar shrinks as one, to three quarters at most.
struct StatusLineView: View {
    let line: StatusLine
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10.5
    /// The width the bar gives the line, and the line's own at full size.
    @State private var room: CGFloat?
    @State private var natural: CGFloat?

    var body: some View {
        HStack(spacing: Self.gap) {
            StatusDot(lit: line.dot == .lit)
            words(size: size * scale)
                .animation(.easeIn(duration: 0.18), value: line)
        }
        .background(alignment: .leading) {
            // The line at full size, never drawn: what it would need.
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: StatusDot.side, height: 1)
                words(size: size)
            }
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    private static let gap: CGFloat = 6

    private var scale: CGFloat {
        guard let room, let natural, natural > room else { return 1 }
        let fixed = StatusDot.side + Self.gap
        // A point to spare, so rounding never cuts the last word.
        return max(0.75, (room - fixed - 1) / max(1, natural - fixed))
    }

    private func words(size: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.pieces(line), id: \.id) { piece in
                piece.text
                    .transition(AsymmetricTransition(insertion: Arrive(), removal: IdentityTransition()))
            }
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .tracking(0.5)
        .lineLimit(1)
    }

    /// The line's parts with the dots between them, each keyed by its words
    /// and the dot, so a part that stays keeps its view.
    private static func pieces(_ line: StatusLine) -> [(id: String, text: Text)] {
        var out = line.parts.enumerated().map { i, part in
            let words = Text(verbatim: part.text).foregroundStyle(color(part.tone))
            let text = i == 0 ? words : Text("\(Text(verbatim: part.joiner).foregroundStyle(Theme.ink2))\(words)")
            return (id: "\(line.dot)|\(part.text)", text: text)
        }
        if line.opens == .help { out.append((id: "\(line.dot)|›", text: Text(verbatim: " ›").foregroundStyle(Theme.ink2))) }
        return out
    }

    private static func color(_ tone: StatusLine.Tone) -> Color {
        switch tone {
        case .ink: return Theme.ink2
        case .live: return Theme.live
        case .alarm: return Theme.alarm
        }
    }
}

/// A new part of the line: it starts faint rather than unseen, so the line
/// is never blank while it arrives.
private struct Arrive: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase.isIdentity ? 1 : 0.35)
    }
}

/// The status dot: lit while live, a hollow ring otherwise. Only its fill
/// changes, never its place: it lights with the spring and cools over
/// 0.4 s; it never pulses.
struct StatusDot: View {
    let lit: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 11

    var body: some View {
        let glow = lit && scheme == .dark && !reduceTransparency
        ZStack {
            // Glow only in dark mode, only while live: two stacked circles,
            // no blur.
            Circle().fill(Theme.live.opacity(0.10)).frame(width: 11, height: 11).opacity(glow ? 1 : 0)
            Circle().fill(Theme.live.opacity(0.22)).frame(width: 8, height: 8).opacity(glow ? 1 : 0)
            Circle().strokeBorder(Theme.ink3, lineWidth: 1).frame(width: 6, height: 6).opacity(lit ? 0 : 1)
            Circle().fill(Theme.live).frame(width: 6, height: 6).opacity(lit ? 1 : 0)
        }
        .frame(width: Self.side, height: Self.side)
        .animation(reduceMotion ? nil : (lit ? Theme.spring : .easeOut(duration: 0.4)), value: lit)
        .accessibilityHidden(true)
    }
}
