import FTWKit
import SwiftUI

// The car first, on a box that keeps cars (docs/cars.md in srcfl/ftw): its
// name and level in large type with where the level comes from and how old
// it is, its charge limit, its goal and plan. The charger is one line under
// it, only while the car is on it. A car that is not plugged in still shows,
// with its last level and its age.

/// The car's own words; Swedish beside them in `CarWords`.
func C(_ en: String) -> String { CarWords.text(en) }

/// The car's name over its level, the 10-cell meter, where the level comes
/// from and how old it is, and the limit the car reported. The level is a
/// reading, never live: ink, held still, faint when FTW assumes it.
struct CarHero: View {
    let car: Car
    let cars: CarsModel
    let site: SiteModel
    let zone: TimeZone
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 60

    var body: some View {
        let level = cars.level(car)
        let faint = level?.guessed ?? true
        VStack(alignment: .leading, spacing: 4) {
            Text(car.shownName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .accessibilityIdentifier("car.name")
            Text(level.map(CarText.percent) ?? "—")
                .font(Theme.figure(figureSize))
                .tracking(-1)
                .foregroundStyle(faint ? Theme.ink3 : Theme.ink)
                .contentTransition(.numericText(value: level?.pct ?? 0))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier("car.level")
            if let level {
                CellMeter(pct: level.pct, tint: Theme.car, live: !faint, glows: false)
                    .frame(width: 120, height: 5)
                    .padding(.bottom, 4)
            }
            Text(level.map { CarText.origin($0, nowMs: site.minuteMs, zone: zone) } ?? C("Level unknown"))
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .contentTransition(.opacity)
                .accessibilityIdentifier("car.origin")
            if let limit = CarText.limit(car) {
                Text(limit)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }
}

/// The charger the car is on, in one line, and what it does; or that the
/// car is not plugged in.
struct ChargerLine: View {
    let car: Car
    let lp: Loadpoint?
    let model: LoadpointsModel
    let cars: CarsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lp {
                Text(CarText.charger(lp))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("car.charger")
                if let c = lp.chargerCar, let note = CarText.identified(c, name: { cars.car($0)?.shownName }) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                }
            } else {
                Text(C("Not plugged in"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("car.charger")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Which car?" with one button per car the box offers, and "None of
/// these". One tap names the plug-in's car; the receipt under it says how
/// far the box has confirmed it.
struct WhichCar: View {
    let lp: Loadpoint
    let cars: CarsModel
    let canChoose: Bool

    var body: some View {
        let choices = cars.choices(lp)
        let step = cars.choice[lp.id]
        VStack(alignment: .leading, spacing: 10) {
            Kicker(C("Which car?"))
            Text(CarWords.format("Which car is on %@?", CarText.chargerName(lp)))
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if canChoose {
                FlowRow(spacing: 8) {
                    ForEach(choices) { car in
                        chip(car.shownName, chosen: step?.carID == car.id, id: car.id) { await cars.choose(lp, carID: car.id) }
                    }
                    chip(C("None of these"), chosen: step?.carID == "", id: "none") { await cars.choose(lp, carID: nil) }
                }
                .disabled(step.map { !$0.settled } ?? false)
                Text(C("Until you choose, FTW charges it as a visitor's car, from spare solar."))
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(C("Tap the car so FTW plans for its level and goal."))
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
            }
            if let step {
                let said = cars.choiceText(step)
                CommandReceipt(receipt: cars.choiceReceipt(step), text: said.text, tone: said.tone)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: step)
        .sensoryFeedback(trigger: step?.result) { _, result in
            switch result {
            case .applied?: return .success
            case .unconfirmed?: return .warning
            case .refused?: return .error
            case nil: return nil
            }
        }
        .accessibilityIdentifier("car.which")
    }

    private func chip(_ title: String, chosen: Bool, id: String, action: @escaping @MainActor () async -> Void) -> some View {
        Group {
            if chosen {
                Button { Task { await action() } } label: { label(title).foregroundStyle(Theme.ground) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
            } else {
                Button { Task { await action() } } label: { label(title).foregroundStyle(Theme.ink) }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityIdentifier("car.which.\(id)")
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
    }
}

/// Buttons in a row that wraps when they run out of width.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let next = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.items.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.items + [i], next, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// How full the car is, told by tap, as the car's own level
/// (`car.soc.set`). A level the car reported is corrected only on purpose.
struct CarLevelBlock: View {
    let car: Car
    let cars: CarsModel
    let canControl: Bool
    @State private var correcting = false

    var body: some View {
        let level = cars.level(car)
        let fromCar = level?.source == .vehicle && level?.estimate == false
        VStack(alignment: .leading, spacing: 10) {
            Kicker(L("How full is the car?"))
            if level == nil || level?.source == .assumed {
                Text(canControl ? L("Nobody has told FTW the car's level yet. Choose it below.") : C("Level unknown"))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canControl {
                if fromCar, !correcting {
                    Button(L("Correct the level")) {
                        withAnimation(Theme.spring) { correcting = true }
                    }
                    .buttonStyle(.glass)
                } else {
                    LevelChips(current: cars.chosenLevel(car) ?? level?.pct ?? EVText.assumedPct) { pct in
                        Task { await cars.setLevel(car, pct: pct) }
                    }
                }
            }
            if let receipt = cars.receipt(level: car), let outcome = cars.outcome(level: car) {
                CommandReceipt(receipt: receipt, text: outcome.text, tone: outcome.tone)
                    .transition(.opacity)
            }
            if fromCar, !correcting, canControl {
                Text(L("Only correct it if the car shows something else."))
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
            }
        }
        .animation(Theme.spring, value: cars.receipt(level: car))
        .sensoryFeedback(.selection, trigger: cars.chosenLevel(car))
        .sensoryFeedback(trigger: cars.outcome(level: car)?.tone) { _, tone in LevelBlock.feedback(tone) }
    }
}

/// The car's goal, one per car, used wherever it is plugged in; on a
/// charger, whether the plan makes it.
struct CarGoalBlock: View {
    let car: Car
    let lp: Loadpoint?
    let cars: CarsModel
    let model: LoadpointsModel
    let site: SiteModel
    @Binding var editing: Bool

    var body: some View {
        let zone = model.zone
        VStack(alignment: .leading, spacing: 8) {
            Kicker(L("Goal"))
            if let goal = car.goal {
                let s = CarsModel.schedule(goal, nowMs: site.minuteMs, zone: zone)
                Text(EVText.goal(s, at: Date(timeIntervalSince1970: site.minuteMs / 1000), zone: zone))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("car.goal")
                if let lp, let next = EVText.nextGoal(lp, nowMs: site.minuteMs, zone: zone), lp.schedule != nil {
                    Hint(next, tone: Theme.ink2)
                } else {
                    Hint(AppWords.format("Next: %@", AppWords.day(EVText.nextDeadlineMs(s, nowMs: site.minuteMs, zone: zone), nowMs: site.minuteMs, zone: zone)), tone: Theme.ink2)
                }
                if let lp, let r = model.readiness(lp) {
                    Readiness(readiness: r, text: EVText.readiness(r, level: model.level(lp), nowMs: site.minuteMs, zone: zone))
                }
                if cars.canControl {
                    Button(L("Change")) { editing = true }
                        .buttonStyle(.glass)
                }
            } else {
                Text(L("No goal yet. Without one, FTW only charges from spare solar."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if cars.canControl {
                    HStack(spacing: 8) {
                        Button {
                            let g = EVText.suggestedGoal
                            Task { await cars.saveGoal(car, socPct: g.socPct, clock: g.clock, recurring: true, days: g.days) }
                        } label: {
                            Text(AppWords.format("Use %@", EVText.suggestedGoalText()))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                        Button(L("Change")) { editing = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
            }
            if let save = cars.goalSave[car.id], !editing {
                Hint(LoadpointsModel.goalText(save), tone: { if case .failed = save { return Theme.alarm }; return Theme.ink2 }())
            }
        }
        .sensoryFeedback(trigger: cars.goalSave[car.id]) { _, save in
            switch save {
            case .saved?, .removed?: return .success
            case .failed?: return .error
            default: return nil
            }
        }
    }
}

/// A plug-in the box cannot name and no longer asks about: a visitor's.
struct VisitorLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(C("A visitor's car"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text(C("FTW does not know this car, so it shows no level."))
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
