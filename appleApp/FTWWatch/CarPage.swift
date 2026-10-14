import FTWShared
import SwiftUI

/// The car as the box last described it, dated, and the three commands:
/// Charge now, Pause and Back to the plan. Each asks once more, goes
/// through the phone, and shows the box's receipt under the buttons.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.context?.cars == nil {
                        // Nothing read yet is not "no charger": the shape of
                        // the page until the phone says.
                        CarBlock(car: .shape, model: model, ask: { _ in })
                            .redacted(reason: .placeholder)
                            .disabled(true)
                    } else if cars.isEmpty {
                        Text(WatchWord.noCharger.text)
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                    }
                    ForEach(cars) { car in
                        CarBlock(car: car, model: model, ask: { asking = $0 })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(WatchWord.car.text)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(car.levelText ?? "—")
                    .font(Theme.figure(26))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let cells = car.cells {
                    Meter(cells: cells, hue: Theme.car)
                }
            }
            Text(car.state)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink)
            if let line = [car.goal, car.next].compactMap({ $0 }).nilIfEmpty?.joined(separator: " · ") {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(Theme.ink2)
            }
            Text(car.asOf)
                .font(Theme.mono(.caption2))
                .foregroundStyle(Theme.ink3)

            // Room for the receipt, above the buttons, so nothing moves
            // when it lands and it shows where the tap was.
            ZStack(alignment: .topLeading) {
                ReceiptLine(receipt: WatchReceipt(commandID: "", op: .mode(""), sent: .waiting, accepted: .waiting, confirmed: .waiting, text: "\n", tone: .working))
                    .hidden()
                    .accessibilityHidden(true)
                if let r = model.receipt(for: car.loadpointID) {
                    ReceiptLine(receipt: r)
                } else if !model.canSend {
                    Text(WatchWord.phoneUnreachable.text)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                }
            }
            let sending = model.sending(car.loadpointID)
            let off = !model.canSend || sending
            VStack(spacing: 4) {
                command(WatchWord.chargeNow.text, .chargeNow(loadpointID: car.loadpointID), WatchWord.chargeNowAsk.text, off: off)
                    .accessibilityIdentifier("watch.car.chargeNow")
                command(WatchWord.pause.text, .pause(loadpointID: car.loadpointID), WatchWord.pauseAsk.text, off: off)
                command(WatchWord.backToPlan.text, .backToPlan(loadpointID: car.loadpointID), WatchWord.backToPlanAsk.text, off: off)
            }
            .padding(.top, 2)
        }
    }

    private func command(_ title: String, _ op: WatchCommand.Op, _ question: String, off: Bool) -> some View {
        Button(title) { ask(CarPage.Ask(op: op, question: question, action: title)) }
            .buttonStyle(.bordered)
            .disabled(off)
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
