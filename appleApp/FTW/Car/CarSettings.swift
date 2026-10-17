import FTWKit
import SwiftUI

/// The owner's cars, in Settings: each with its level, into its own page;
/// and a way to add one. The box keeps the list; each change is one
/// command, and the list is read again after it.
struct CarsSettingsView: View {
    let cars: CarsModel
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(cars.ordered) { car in
                    NavigationLink { CarSettingsView(cars: cars, id: car.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(car.shownName).foregroundStyle(Theme.ink)
                            Text(line(car))
                                .font(.footnote)
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("settings.car.\(car.id)")
                }
                if cars.cars.isEmpty {
                    Text(C("No car yet"))
                        .foregroundStyle(Theme.ink2)
                }
            } footer: {
                Text(cars.canEdit ? C("The cars FTW plans for. Each keeps its own level, goal and sources.") : C("Only the home's owner can change the cars."))
            }
            if cars.canEdit {
                Section {
                    Button { adding = true } label: {
                        Label(C("Add a car"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings.cars.add")
                    if let edit = cars.edit[CarsModel.newCarKey] {
                        Text(CarsModel.editText(edit))
                            .font(.footnote)
                            .foregroundStyle(edit.isFailure ? Theme.alarm : Theme.ink2)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(C("Cars"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Theme.spring, value: cars.cars)
        .refreshable { try? await cars.load() }
        .onAppear { cars.activate() }
        .onDisappear { cars.deactivate() }
        .sheet(isPresented: $adding) { AddCarView(cars: cars) }
    }

    /// "72 % · from the car · 1 h ago · On Easee"
    private func line(_ car: Car) -> String {
        var parts: [String] = []
        if let level = cars.level(car) {
            parts.append(CarText.percent(level) + " · " + CarText.origin(level, nowMs: Date().timeIntervalSince1970 * 1000, zone: .current))
        } else {
            parts.append(C("Level unknown"))
        }
        parts.append(cars.charger(of: car).map { CarWords.format("On %@", CarText.chargerName($0)) } ?? C("Not plugged in"))
        return parts.joined(separator: " · ")
    }
}

extension CarsModel.Edit {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One car: its name, its battery, the sources that report its level, and
/// removing it. Name and battery go together with Save; a source goes at
/// once.
struct CarSettingsView: View {
    let cars: CarsModel
    let id: String
    @State private var name = ""
    @State private var kWh: Double = 60
    @State private var started = false
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    private var car: Car? { cars.car(id) }

    var body: some View {
        Group {
            if let car {
                form(car)
            } else {
                Text(C("FTW no longer has this car."))
                    .foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .navigationTitle(car?.shownName ?? C("Car"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !started, let car else { return }
            started = true
            name = car.name
            kWh = car.capacityWh > 0 ? (car.capacityWh / 1000).rounded() : 60
        }
    }

    private func form(_ car: Car) -> some View {
        let canEdit = cars.canEdit
        let choices = cars.sourceChoices(for: car)
        let changed = name.trimmingCharacters(in: .whitespacesAndNewlines) != car.name || (kWh * 1000).rounded() != car.capacityWh.rounded()
        return Form {
            Section(C("Name")) {
                TextField(C("Name"), text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(!canEdit)
                    .accessibilityIdentifier("car.settings.name")
            }
            .listRowBackground(Theme.raised)
            Section(C("Battery size")) {
                Stepper(value: $kWh, in: 10...200, step: 1) {
                    Text(CarWords.format("%@ kWh", String(Int(kWh))))
                        .font(Theme.figure(22))
                }
                .disabled(!canEdit)
            }
            .listRowBackground(Theme.raised)
            if canEdit {
                Section {
                    Button(L("Save")) {
                        Task { await cars.update(car, name: name, capacityWh: kWh * 1000) }
                    }
                    .disabled(!changed || name.trimmingCharacters(in: .whitespaces).isEmpty || cars.edit[car.id] == .saving)
                    .accessibilityIdentifier("car.settings.save")
                    if let edit = cars.edit[car.id] {
                        Text(CarsModel.editText(edit))
                            .font(.footnote)
                            .foregroundStyle(edit.isFailure ? Theme.alarm : Theme.ink2)
                    }
                }
                .listRowBackground(Theme.raised)
            }
            Section {
                ForEach(choices, id: \.self) { source in
                    Toggle(source, isOn: Binding(
                        get: { car.sources.contains(source) },
                        set: { on in
                            let next = on ? car.sources + [source] : car.sources.filter { $0 != source }
                            Task { await cars.update(car, sources: next) }
                        }
                    ))
                    .font(.body.monospaced())
                    .disabled(!canEdit || cars.edit[car.id] == .saving)
                }
                if choices.isEmpty {
                    Text(C("No source reports this car's level yet."))
                        .foregroundStyle(Theme.ink2)
                }
            } header: {
                Text(C("Level sources"))
            } footer: {
                if car.sources.isEmpty, !choices.isEmpty { Text(C("No source reports this car's level yet.")) }
            }
            .listRowBackground(Theme.raised)
            if canEdit {
                Section {
                    Button(C("Remove this car"), role: .destructive) { confirmingRemove = true }
                        .accessibilityIdentifier("car.settings.remove")
                }
                .listRowBackground(Theme.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog(CarWords.format("Remove %@?", car.shownName), isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(C("Remove"), role: .destructive) {
                Task {
                    await cars.remove(car)
                    if cars.edit[car.id] == .removed { dismiss() }
                }
            }
        } message: {
            Text(C("FTW forgets the car and its goal. A session on it becomes a visitor's."))
        }
    }
}

/// A new car: a name and its battery. The phone mints its id, the same on
/// every box its owner has.
struct AddCarView: View {
    let cars: CarsModel
    @State private var name = ""
    @State private var kWh: Double = 60
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(C("Name")) {
                    TextField(C("New car"), text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("car.add.name")
                }
                .listRowBackground(Theme.raised)
                Section(C("Battery size")) {
                    Stepper(value: $kWh, in: 10...200, step: 1) {
                        Text(CarWords.format("%@ kWh", String(Int(kWh))))
                            .font(Theme.figure(22))
                    }
                }
                .listRowBackground(Theme.raised)
                if case .failed(let why)? = cars.edit[CarsModel.newCarKey], !saving {
                    Section {
                        Text(why).foregroundStyle(Theme.alarm)
                    }
                    .listRowBackground(Theme.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle(C("Add a car"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(C("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(C("Add")) {
                            Task {
                                saving = true
                                await cars.add(name: name, capacityWh: kWh * 1000)
                                saving = false
                                if cars.edit[CarsModel.newCarKey] == .saved { dismiss() }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("car.add.save")
                    }
                }
            }
        }
    }
}
