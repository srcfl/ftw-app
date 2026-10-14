import FTWShared
import SwiftUI

/// The car on one screen: its level as the 10-cell meter, what it does,
/// when that was read, its goal and next window, and the three commands as
/// one row of buttons. Each asks once more and names itself in full there.
/// The box's answers come back as the receipt, which takes the place of
/// what the car does until the page is left.
///
/// With more than one charger, the one with a car plugged in shows.
struct CarPage: View {
    let model: WatchModel
    @State private var asking: Ask?

    struct Ask: Identifiable {
        let op: WatchCommand.Op
        let question: String
        let action: String
        var id: String { action }
    }

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let cars = WatchGlance.cars(model.context?.cars, plan: model.context?.plan?.value, nowMs: nowMs, zone: model.zone)
            let car = cars.first(where: \.pluggedIn) ?? cars.first
            Group {
                if let car {
                    OnePage { CarBlock(car: car, model: model, ask: { asking = $0 }) }
                } else if model.context?.cars == nil {
                    // Nothing read yet is not "no charger": the shape of the
                    // page until the phone says.
                    CarBlock(car: .shape, model: model, ask: { _ in })
                        .redacted(reason: .placeholder)
                        .disabled(true)
                } else {
                    Text(WatchWord.noCharger.text)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .navigationTitle(WatchWord.car.text)
        .onDisappear { model.leaveCars() }
        .sheet(item: $asking) { a in
            Confirm(question: a.question, action: a.action) { model.send(a.op) }
        }
    }
}

private struct CarBlock: View {
    let car: WatchGlance.Car
    let model: WatchModel
    let ask: (CarPage.Ask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // "20 % antaget": a level FTW assumed says so.
                Text(car.levelText ?? "—")
                    .font(Theme.figure(22))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let cells = car.cells {
                    Meter(cells: cells, hue: Theme.car)
                }
            }
            // One room for what the car does or, after a command, the box's
            // receipt, so nothing moves when the receipt lands.
            ZStack(alignment: .topLeading) {
                ReceiptLine(receipt: WatchReceipt(commandID: "", op: .mode(""), sent: .waiting, accepted: .waiting, confirmed: .waiting, text: "\n", tone: .working))
                    .hidden()
                    .accessibilityHidden(true)
                if let r = model.receipt(for: car.loadpointID) {
                    ReceiptLine(receipt: r)
                } else {
                    state
                }
            }
            Spacer(minLength: 0)
            let off = !model.canSend || model.sending(car.loadpointID)
            HStack(spacing: 6) {
                command("bolt.fill", WatchWord.chargeNow.text, .chargeNow(loadpointID: car.loadpointID), WatchWord.chargeNowAsk.text, off: off, on: car.holding)
                    .accessibilityIdentifier("watch.car.chargeNow")
                command("pause.fill", WatchWord.pause.text, .pause(loadpointID: car.loadpointID), WatchWord.pauseAsk.text, off: off, on: false)
                command("arrow.uturn.backward", WatchWord.backToPlan.text, .backToPlan(loadpointID: car.loadpointID), WatchWord.backToPlanAsk.text, off: off, on: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What it does and when the box said so, then its goal and next
    /// window, or why the buttons are off.
    private var state: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(car.state)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(car.asOf)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Goal and next window on a line each; one line for both when
            // the second says why the buttons are off.
            if model.canSend {
                ForEach([car.goal, car.next].compactMap { $0 }, id: \.self) { line($0) }
            } else {
                line([car.goal, car.next].compactMap { $0 }.joined(separator: " · "))
                line(WatchWord.phoneUnreachable.text)
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// One command: a glyph on the button, its full name in the question
    /// and to VoiceOver. `on` marks the one the box last confirmed as
    /// holding.
    private func command(_ glyph: String, _ title: String, _ op: WatchCommand.Op, _ question: String, off: Bool, on: Bool) -> some View {
        Button {
            ask(CarPage.Ask(op: op, question: question, action: title))
        } label: {
            // Lower than the system's bordered button, so the page needs no
            // scrolling; still a whole third of the width to hit.
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Theme.car : Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(off)
        .opacity(off ? 0.4 : 1)
        .accessibilityLabel(title)
    }
}
