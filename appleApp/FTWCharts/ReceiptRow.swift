import FTWShared
import SwiftUI

/// The receipt log, `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED`, in the
/// terminal layer: one line of SF Mono caps with every slot always there,
/// so lighting one never moves another. A lit slot is ink, a waiting one
/// ink3; CONFIRMED is lime, and REFUSED takes its place in alarm red.
///
/// `dimmed` draws every slot in ink3 and keeps the lit ones a little
/// stronger: a card the phone can no longer vouch for still says how far
/// the command came, without the colour of a state.
struct ReceiptRow: View {
    let receipt: ReceiptLog
    var dimmed = false
    var size: CGFloat = 10.5

    var body: some View {
        receipt.marks.enumerated().reduce(Text(verbatim: "")) { line, item in
            let (i, mark) = item
            let word = Text(verbatim: mark.text).foregroundStyle(color(mark))
            return i == 0 ? word : Text("\(line)\(arrow)\(word)")
        }
        .font(.system(size: size, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityLabel(receipt.line)
    }

    private var arrow: Text { Text(verbatim: ReceiptLog.arrow).foregroundStyle(Theme.ink3) }

    private func color(_ mark: ReceiptLog.Mark) -> Color {
        switch (mark.state, dimmed) {
        case (.waiting, _): return Theme.ink3.opacity(dimmed ? 0.6 : 1)
        case (.lit, true), (.refused, true): return Theme.ink3
        case (.lit, false): return mark.slot == .confirmed ? Theme.live : Theme.ink
        case (.refused, false): return Theme.alarm
        }
    }
}
