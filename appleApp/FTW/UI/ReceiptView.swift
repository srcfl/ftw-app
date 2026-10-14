import FTWKit
import SwiftUI

/// The room a receipt takes, its marks and two lines of text, laid out as
/// `ReceiptView` lays them out and left empty, so a receipt that arrives
/// moves nothing.
struct ReceiptRoom: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { marks }
                VStack(alignment: .leading, spacing: 4) { marks }
            }
            Text(verbatim: "\n")
                .font(.footnote.weight(.medium))
        }
        .padding(.vertical, 4)
        .hidden()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var marks: some View {
        ForEach([L("Sent"), L("Received"), L("Done")], id: \.self) { label in
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text(label).font(.caption.weight(.semibold))
            }
        }
    }
}

/// The receipt under a control: sent, received, done, and one sentence.
struct ReceiptView: View {
    let outcome: EVText.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { marks }
                VStack(alignment: .leading, spacing: 4) { marks }
            }
            Text(outcome.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .animation(Theme.spring, value: outcome)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marks: some View {
        mark(L("Sent"), outcome.sent)
        mark(L("Received"), outcome.received)
        mark(L("Done"), outcome.done)
    }

    private func mark(_ label: String, _ state: EVText.Outcome.Mark) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(state))
                .foregroundStyle(tint(state))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .active)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .waiting ? Theme.fgMuted : Theme.fg)
        }
    }

    private func symbol(_ state: EVText.Outcome.Mark) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .active: return "circle.dotted.circle"
        case .waiting: return "circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func tint(_ state: EVText.Outcome.Mark) -> Color {
        switch state {
        case .done: return Theme.live
        case .active: return Theme.accent
        case .waiting: return Theme.fgMuted
        case .failed: return Theme.alarm
        }
    }

    private var color: Color {
        switch outcome.tone {
        case .working: return Theme.fgDim
        case .done: return Theme.live
        case .warning: return Theme.alarm
        case .failed: return Theme.alarm
        }
    }
}
