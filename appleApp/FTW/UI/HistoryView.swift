import Charts
import FTWKit
import SwiftUI

/// What the house used, made, bought and sold, then power minute by minute.
struct HistoryView: View {
    let home: HomeModels

    var body: some View {
        Group {
            if home.site.hasPassthrough {
                EnergySection(energy: home.energy)
                Divider().overlay(Theme.line)
            }
            PowerSection(history: home.history)
        }
        .onAppear {
            home.energy.activate()
            home.history.activate()
        }
        .onDisappear {
            home.energy.deactivate()
            home.history.deactivate()
        }
    }
}

// MARK: Energy, day by day

private struct EnergySection: View {
    let energy: EnergyModel
    @State private var shown: Series = .load

    enum Series: CaseIterable {
        case load, pv, bought, sold

        var label: String {
            switch self {
            case .load: return "Used at home"
            case .pv: return "Made by solar"
            case .bought: return "Bought"
            case .sold: return "Sold"
            }
        }

        var note: String {
            switch self {
            case .load: return "everything the house drew"
            case .pv: return "what the panels produced"
            case .bought: return "taken from the grid"
            case .sold: return "sent back to the grid"
            }
        }

        var color: Color {
            switch self {
            case .load: return Theme.fgDim
            case .pv: return Theme.generation
            case .bought: return Theme.importing
            case .sold: return Theme.exporting
            }
        }

        func wh(_ t: EnergyModel.Totals) -> Double {
            switch self {
            case .load: return t.loadWh
            case .pv: return t.pvWh
            case .bought: return t.importWh
            case .sold: return t.exportWh
            }
        }

        func wh(_ d: EnergyModel.Day) -> Double {
            switch self {
            case .load: return d.loadWh
            case .pv: return d.pvWh
            case .bought: return d.importWh
            case .sold: return d.exportWh
            }
        }
    }

    var body: some View {
        let totals = energy.totals
        let hasDays = !energy.days.isEmpty
        HStack {
            Kicker(energy.range.title)
            Spacer()
            Segments(options: EnergyModel.Range.allCases, selected: energy.range, label: \.label) { energy.select($0) }
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Series.allCases, id: \.self) { series in
                let parts = EnergyFormat.parts(series.wh(totals))
                Button { shown = series } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(series.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
                        Group {
                            if hasDays {
                                Text(parts.text).font(Theme.number(22)) + Text(" \(parts.unit)").font(.caption)
                            } else {
                                Text("—").font(Theme.number(22))
                            }
                        }
                        .foregroundStyle(series == .load ? Theme.fg : series.color)
                        Text(series.note).font(.caption2).foregroundStyle(Theme.fgMuted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(shown == series ? series.color : Theme.line, lineWidth: shown == series ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shown == series ? .isSelected : [])
            }
        }
        if hasDays, energy.days.count > 1 {
            Text("\(shown.label), kWh per day").font(.caption).foregroundStyle(Theme.fgDim)
            Chart(energy.days) { day in
                BarMark(x: .value("Day", day.day), y: .value("kWh", shown.wh(day) / 1000))
                    .foregroundStyle(shown.color)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let day = value.as(String.self) { Text(Self.dayLabel(day)).font(.caption2) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel()
                }
            }
            .frame(height: 140)
        }
        note(totals: totals, hasDays: hasDays)
    }

    @ViewBuilder private func note(totals: EnergyModel.Totals, hasDays: Bool) -> some View {
        if let error = energy.error {
            Hint(error)
        } else if !hasDays {
            Hint(energy.loading || !energy.loaded ? "Reading your box…" : "Nothing recorded for this period yet.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let share = energy.solarSharePct {
                    Hint("Solar made \(share)% as much energy as the home used.")
                }
                if totals.batChargedWh > 0 || totals.batDischargedWh > 0 {
                    Hint("The battery took in \(EnergyFormat.label(totals.batChargedWh)) and gave back \(EnergyFormat.label(totals.batDischargedWh)).")
                }
                if energy.range != .today {
                    Hint("Today is still running.", tone: Theme.fgMuted)
                }
            }
        }
    }

    /// "2026-09-24" to "24 Sep", short enough for thirty bars.
    static func dayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: Power, minute by minute

private struct PowerSection: View {
    let history: HistoryModel

    private struct Trace {
        let name: String
        let label: String
        let color: Color
    }

    private let traces = [
        Trace(name: "grid_w", label: "Grid", color: Theme.importing),
        Trace(name: "pv_w", label: "Solar", color: Theme.generation),
        Trace(name: "battery_w", label: "Battery", color: Theme.storage),
        Trace(name: "load_w", label: "House", color: Theme.fgDim),
    ]

    var body: some View {
        HStack {
            Kicker("Power, minute by minute")
            Spacer()
            Segments(options: HistoryModel.Range.allCases, selected: history.range, label: \.label) { history.select($0) }
        }
        Group {
            if let frame = history.frame, frame.points > 0 {
                chart(frame)
            } else {
                Text(history.loaded ? "Nothing recorded for this range yet." : "Reading your box…")
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
        }
        readout
        if !history.note.isEmpty {
            Hint(history.note)
        }
    }

    private func chart(_ frame: HistoryGeometry.Frame) -> some View {
        let step = max(1, frame.points / 400)
        let indices = Array(stride(from: 0, to: frame.points, by: step))
        let spanMs = Double(frame.points) * frame.stepMs
        // A day reads as clock times; anything longer as dates.
        let format: Date.FormatStyle = spanMs <= 36 * 3_600_000 ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated)
        return Chart {
            ForEach(traces, id: \.name) { trace in
                ForEach(indices, id: \.self) { i in
                    if let v = frame.value(trace.name, at: i) {
                        LineMark(
                            x: .value("Time", Date(timeIntervalSince1970: frame.time(at: i) / 1000)),
                            y: .value("Watts", Double(v)),
                            series: .value("Series", trace.label)
                        )
                        .foregroundStyle(trace.color)
                        .lineStyle(StrokeStyle(lineWidth: trace.name == "load_w" ? 1 : 1.5))
                    }
                }
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
            if let at = history.cursorAtMs {
                RuleMark(x: .value("Cursor", Date(timeIntervalSince1970: at / 1000)))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let w = value.as(Double.self) {
                        Text(w == 0 ? "0" : "\(PowerFormat.scale(w))\(w > 0 ? " in" : " out")").font(Theme.number(9, weight: .regular))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: format)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let plot = proxy.plotFrame else { return }
                                let x = drag.location.x - geo[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let index = Int(((date.timeIntervalSince1970 * 1000 - frame.startMs) / frame.stepMs).rounded())
                                history.cursor = min(frame.points - 1, max(0, index))
                            }
                            .onEnded { _ in history.cursor = nil }
                    )
            }
        }
        .frame(height: 220)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(history.cursorAtMs.map(Clock.dayAndTime) ?? "Latest")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.fgDim)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(traces, id: \.name) { trace in
                    let watts = history.value(trace.name)
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(trace.color).frame(width: 4, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trace.label).font(.caption2).foregroundStyle(Theme.fgDim)
                            if let watts {
                                let parts = PowerFormat.parts(watts)
                                Text(parts.text).font(Theme.number(15)) + Text(" \(parts.unit)").font(.caption2)
                            } else {
                                Text("—").font(Theme.number(15))
                            }
                            Text(words(trace.name, watts)).font(.caption2).foregroundStyle(Theme.fgMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Never a minus sign; a direction word instead.
    private func words(_ name: String, _ watts: Double?) -> String {
        guard let watts else { return "no reading" }
        if name == "load_w" { return "used" }
        let direction = PowerFormat.direction(watts)
        if direction == .idle { return "idle" }
        switch name {
        case "pv_w": return "generated"
        case "battery_w": return direction == .into ? "charged" : "supplied"
        default: return direction == .into ? "drawn" : "exported"
        }
    }
}
