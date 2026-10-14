import FTWShared
import SwiftUI

// Phosphor on the wrist: light means live. Only a reading the phone just
// passed on live may light up; everything else is ink and holds still.
// Four of the phone's six TUI details travel here: the status line, the
// 10-cell meter, the receipt log and the lit dot. The block price bars
// live on the dial and the price page.

/// The mono status line: `● LIVE · FTW IN CONTROL`, `○ AS OF 14:05`.
struct StatusLine: View {
    let status: WatchGlance.Status

    var body: some View {
        HStack(spacing: 4) {
            LitDot(isLive: status.lit)
            Text(status.text)
                .font(Theme.mono(.caption2))
                .foregroundStyle(status.alarm ? Theme.alarm : Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The phosphor dot: lit lime while live, a hollow ink ring otherwise. It
/// ignites with the spring and decays like a CRT, never pulses. The glow
/// is stacked circles, not a blur, and takes `isLive`, so a cache cannot
/// glow.
struct LitDot: View {
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Theme.live.opacity(isLive ? 0.18 : 0)).frame(width: 11, height: 11)
            Circle().fill(Theme.live.opacity(isLive ? 0.35 : 0)).frame(width: 8, height: 8)
            Circle().fill(isLive ? Theme.live : .clear).frame(width: 5.5, height: 5.5)
            Circle().stroke(Theme.ink3, lineWidth: 1).frame(width: 5.5, height: 5.5).opacity(isLive ? 0 : 1)
        }
        .frame(width: 11, height: 11)
        .animation(reduceMotion ? nil : (isLive ? Theme.spring : .easeOut(duration: 0.4)), value: isLive)
    }
}

/// Level in tenths, readable at a glance: ten cells, the full ones in the
/// kind's hue.
struct Meter: View {
    let cells: Int
    let hue: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < cells ? hue : Theme.ink3.opacity(0.35))
                    .frame(width: 5, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The receipt log: `SENT ▸ ACCEPTED ▸ CONFIRMED` and one sentence. A mark
/// is ink once done, ink2 while under way, ink3 while it waits and alarm
/// when it failed. CONFIRMED turns lime only on the box's confirmation.
struct ReceiptLine: View {
    let receipt: WatchReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(mark(WatchWord.sent.text, receipt.sent, confirmed: false))\(arrow)\(mark(WatchWord.accepted.text, receipt.accepted, confirmed: false))\(arrow)\(mark(WatchWord.confirmed.text, receipt.confirmed, confirmed: true))")
                .font(Theme.mono(.caption2, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(receipt.text)
                .font(.footnote)
                .foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(Theme.spring, value: receipt)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.receipt")
    }

    private var arrow: Text { Text(verbatim: " ▸ ").foregroundStyle(Theme.ink3) }

    private func mark(_ label: String, _ m: WatchReceipt.Mark, confirmed: Bool) -> Text {
        let color: Color
        switch m {
        case .done: color = confirmed ? Theme.live : Theme.ink
        case .active: color = Theme.ink2
        case .waiting: color = Theme.ink3
        case .failed: color = Theme.alarm
        }
        return Text(verbatim: m == .failed ? "✕ \(label)" : label).foregroundStyle(color)
    }

    private var tone: Color {
        switch receipt.tone {
        case .working: return Theme.ink2
        case .done: return Theme.live
        case .warning, .failed: return Theme.alarm
        }
    }
}

/// Each energy kind's one hue. The battery has two: it stores in cyan and
/// gives in gold. The home is ink.
enum Hue {
    static func of(_ node: WatchNow.Node, way: WatchNow.Way) -> Color {
        switch node {
        case .solar: return Theme.solar
        case .battery: return way == .giving ? Theme.gives : Theme.stores
        case .home: return Theme.ink
        case .grid: return Theme.grid
        case .car: return Theme.car
        }
    }
}

extension Theme {
    /// The phone's one spring (`FTW/UI/Theme.swift`), so the watch moves
    /// as the app does.
    static let spring = Animation.spring(duration: 0.35, bounce: 0.15)
}
