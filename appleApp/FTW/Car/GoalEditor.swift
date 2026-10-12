import FTWKit
import SwiftUI

/// The goal: how full, by when, on which days. One Save, one PUT. The time
/// is set and shown on the household clock, the one the box keeps.
struct GoalEditor: View {
    let model: LoadpointsModel
    let lp: Loadpoint
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

    init(model: LoadpointsModel, lp: Loadpoint) {
        self.model = model
        self.lp = lp
        let zone = model.zone
        let now = Date()
        let s = lp.schedule
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
        let c = Self.calendar(model.zone).dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var choices: [Days] {
        var out: [Days] = [.weekdays, .everyDay, .weekends, .once]
        if case .custom = days { out.insert(days, at: 0) }
        return out
    }

    private var failure: String? {
        if case .failed(let help)? = model.goalSave[lp.id], !saving { return help }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Charge to")) {
                    Stepper(value: $socPct, in: 10...100, step: 5) {
                        Text(AppWords.percent(socPct)).font(Theme.percent(.title2))
                    }
                }
                Section(L("Ready by")) {
                    DatePicker(L("Ready by"), selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .environment(\.timeZone, model.zone)
                        .frame(maxWidth: .infinity)
                }
                Section(L("Repeat")) {
                    Picker(L("Repeat"), selection: $days) {
                        ForEach(choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text(preview).font(.subheadline).foregroundStyle(Theme.fgDim)
                    if let failure {
                        Text(failure).font(.subheadline).foregroundStyle(Theme.importing)
                    }
                }
                if lp.schedule != nil {
                    Section {
                        Button(L("Remove goal"), role: .destructive) {
                            Task {
                                saving = true
                                await model.removeGoal(lp)
                                saving = false
                                if case .removed? = model.goalSave[lp.id] { dismiss() }
                            }
                        }
                        .disabled(saving)
                    }
                }
            }
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
                                await model.saveGoal(lp, socPct: socPct, clock: clock, recurring: days.recurring, days: days.mask, zone: model.zone)
                                saving = false
                                if case .saved? = model.goalSave[lp.id] { dismiss() }
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
        return EVText.goal(s, at: Date(), zone: model.zone)
    }
}
