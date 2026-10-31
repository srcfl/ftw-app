import FTWKit
import SwiftUI

/// The goal: how full, by when, on which days. One Save, one command: the
/// charger's schedule on a box without cars, the car's own goal on one with
/// them. The time is set and shown on the household clock, the one the box
/// keeps.
struct GoalEditor: View {
    let zone: TimeZone
    let hasGoal: Bool
    /// How the last save went, as the model holds it.
    let state: @MainActor () -> LoadpointsModel.GoalSave?
    let save: @MainActor (_ socPct: Double, _ clock: Int, _ recurring: Bool, _ days: Int) async -> Void
    let remove: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var socPct: Double
    @State private var time: Date
    @State private var days: Days
    @State private var saving = false

    enum Days: Hashable {
        case weekdays, everyDay, weekends, once
        case custom(Int)

        init(recurring: Bool, mask: Int) {
            guard recurring else { self = .once; return }
            switch mask & 0x7f {
            case 0, 0x7f: self = .everyDay
            case 0b0011111: self = .weekdays
            case 0b1100000: self = .weekends
            default: self = .custom(mask & 0x7f)
            }
        }

        var recurring: Bool { self != .once }

        var mask: Int {
            switch self {
            case .weekdays: return 0b0011111
            case .everyDay, .once: return 0x7f
            case .weekends: return 0b1100000
            case .custom(let m): return m
            }
        }

        var label: String {
            switch self {
            case .weekdays: return L("Weekdays")
            case .everyDay: return L("Every day")
            case .weekends: return L("Weekends")
            case .once: return L("Once")
            case .custom(let m):
                let days = EVText.days(m)
                return days.prefix(1).uppercased() + days.dropFirst()
            }
        }
    }

    /// A charger's goal, on a box without cars or for a car it cannot name.
    init(model: LoadpointsModel, lp: Loadpoint) {
        self.init(schedule: lp.schedule, zone: model.zone, state: { model.goalSave[lp.id] },
                  save: { await model.saveGoal(lp, socPct: $0, clock: $1, recurring: $2, days: $3, zone: model.zone) },
                  remove: { await model.removeGoal(lp) })
    }

    /// A car's own goal, used wherever it is plugged in.
    init(cars: CarsModel, car: Car, zone: TimeZone) {
        self.init(schedule: car.goal.map { CarsModel.schedule($0, nowMs: Date().timeIntervalSince1970 * 1000, zone: zone) }, zone: zone,
                  state: { cars.goalSave[car.id] },
                  save: { await cars.saveGoal(car, socPct: $0, clock: $1, recurring: $2, days: $3, finishAtLimit: car.goal?.finishAtLimit == true && $0 >= 100) },
                  remove: { await cars.removeGoal(car) })
    }

    private init(schedule s: Loadpoint.Schedule?, zone: TimeZone, state: @escaping @MainActor () -> LoadpointsModel.GoalSave?,
                 save: @escaping @MainActor (Double, Int, Bool, Int) async -> Void, remove: @escaping @MainActor () async -> Void) {
        self.zone = zone
        hasGoal = s != nil
        self.state = state
        self.save = save
        self.remove = remove
        let now = Date()
        _socPct = State(initialValue: s.map { $0.finishAtVehicleLimit ? 100 : $0.socPct } ?? EVText.suggestedGoal.socPct)
        let clock = s.map { EVText.goalClock($0, at: now, zone: zone) } ?? EVText.suggestedGoal.clock
        _time = State(initialValue: Self.date(clock: clock, zone: zone))
        _days = State(initialValue: s.map { Days(recurring: $0.recurring, mask: $0.days) } ?? .weekdays)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// Today at that clock in the household zone, for the time wheel.
    static func date(clock: Int, zone: TimeZone) -> Date {
        let cal = calendar(zone)
        return cal.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: Date()) ?? Date()
    }

    private var clock: Int {
        let c = Self.calendar(zone).dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var choices: [Days] {
        var out: [Days] = [.weekdays, .everyDay, .weekends, .once]
        if case .custom = days { out.insert(days, at: 0) }
        return out
    }

    private var failure: String? {
        if case .failed(let help)? = state(), !saving { return help }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Charge to")) {
                    Stepper(value: $socPct, in: 10...100, step: 5) {
                        Text(AppWords.percent(socPct)).font(Theme.figure(22))
                    }
                }
                .listRowBackground(Theme.raised)
                Section(L("Ready by")) {
                    DatePicker(L("Ready by"), selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .environment(\.timeZone, zone)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Theme.raised)
                Section(L("Repeat")) {
                    Picker(L("Repeat"), selection: $days) {
                        ForEach(choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Theme.raised)
                Section {
                    Text(preview).font(.subheadline).foregroundStyle(Theme.ink2)
                    if let failure {
                        Text(failure).font(.subheadline).foregroundStyle(Theme.alarm)
                    }
                }
                .listRowBackground(Theme.raised)
                if hasGoal {
                    Section {
                        Button(L("Remove goal"), role: .destructive) {
                            Task {
                                saving = true
                                await remove()
                                saving = false
                                if case .removed? = state() { dismiss() }
                            }
                        }
                        .disabled(saving)
                    }
                    .listRowBackground(Theme.raised)
                }
            }
            // FTW's ground under the sheet, its rows raised.
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .accessibilityIdentifier("goal.editor")
            .navigationTitle(L("Goal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(L("Save")) {
                            Task {
                                saving = true
                                await save(socPct, clock, days.recurring, days.mask)
                                saving = false
                                if case .saved? = state() { dismiss() }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The goal as it will read on the car view.
    private var preview: String {
        let s = Loadpoint.Schedule(socPct: socPct, timeOfDayMinUTC: 0, clockMin: clock, surplusUnlockPct: 0, recurring: days.recurring, days: days == .everyDay ? 0 : days.mask, finishAtVehicleLimit: false)
        return EVText.goal(s, at: Date(), zone: zone)
    }
}
