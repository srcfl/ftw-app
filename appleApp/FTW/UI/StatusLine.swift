import FTWKit
import SwiftUI

extension View {
    /// The status line under every screen's title, in the system's own bar,
    /// so it never scrolls away and needs no band of its own. A tap opens
    /// the control sheet.
    func statusLine(app: AppModel, home: HomeModels) -> some View {
        modifier(StatusSubtitle(app: app, home: home))
    }
}

private struct StatusSubtitle: ViewModifier {
    let app: AppModel
    let home: HomeModels
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .subtitle) {
                    StatusLineButton(app: app, home: home) { open = true }
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
/// hollow ring. New words replace the old by id: the old fade out before
/// the new fade in, so two lines never sit on top of each other.
struct StatusLineView: View {
    let line: StatusLine
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(lit: line.dot == .lit)
            ZStack(alignment: .leading) {
                words
                    .id(line.text)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.15)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
            }
            .animation(.default, value: line.text)
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .tracking(0.5)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        // Chrome in the bar: whole words before large letters.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var words: Text {
        var out = Text(verbatim: "")
        for (i, part) in line.parts.enumerated() {
            if i > 0 { out = Text("\(out)\(Text(verbatim: " · ").foregroundStyle(Theme.ink2))") }
            out = Text("\(out)\(Text(verbatim: part.text).foregroundStyle(color(part.tone)))")
        }
        if line.opens == .help { out = Text("\(out)\(Text(verbatim: " ›").foregroundStyle(Theme.ink2))") }
        return out
    }

    private func color(_ tone: StatusLine.Tone) -> Color {
        switch tone {
        case .ink: return Theme.ink2
        case .live: return Theme.live
        case .alarm: return Theme.alarm
        }
    }
}

/// The status dot: lit while live, a hollow ring otherwise. It lights with
/// the spring and cools over 0.4 s; it never pulses.
struct StatusDot: View {
    let lit: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Glow only in dark mode, only while live: two stacked circles,
            // no blur.
            if lit, scheme == .dark, !reduceTransparency {
                Circle().fill(Theme.live.opacity(0.10)).frame(width: 11, height: 11)
                Circle().fill(Theme.live.opacity(0.22)).frame(width: 8, height: 8)
            }
            Circle()
                .fill(lit ? Theme.live : .clear)
                .strokeBorder(lit ? Theme.live : Theme.ink3, lineWidth: 1)
                .frame(width: 6, height: 6)
        }
        .frame(width: 11, height: 11)
        .animation(reduceMotion ? nil : (lit ? Theme.spring : .easeOut(duration: 0.4)), value: lit)
        .accessibilityHidden(true)
    }
}
