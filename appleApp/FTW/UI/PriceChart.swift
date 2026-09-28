import Charts
import FTWKit
import SwiftUI

/// Prices ahead, as bars from zero. Compact on Now: the price this moment
/// and the cheapest two hours. Full on Plan: every slot of today and
/// tomorrow with the moment marked.
struct PriceChart: View {
    let prices: Prices
    let nowMs: Double
    var compact = false

    var body: some View {
        let unit = PriceUnits.unit(prices.currency)
        let summary = PriceStrip.summary(prices, nowMs: nowMs)
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    Kicker("Market now")
                    Text("Electricity price").font(.headline)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(PriceStrip.text(summary.current?.totalMinor, prices.currency)).font(Theme.number(28, weight: .bold)) + Text(" \(unit.perKwh)").font(.caption))
                        Text("\(prices.zone.isEmpty ? "—" : prices.zone) · incl. fees and VAT").font(.caption).foregroundStyle(Theme.fgMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Cheapest 2 h").font(.caption).foregroundStyle(Theme.fgDim)
                        if let block = summary.cheapest {
                            Text("\(PriceStrip.text(block.meanMinor, prices.currency)) \(unit.label)").font(Theme.number(15)).foregroundStyle(Theme.exporting)
                            Text("\(Clock.time(block.startMs))–\(Clock.time(block.endMs))").font(.caption).foregroundStyle(Theme.fgDim)
                        } else {
                            Text("No 2 h window published").font(.caption).foregroundStyle(Theme.fgDim)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if summary.bars.isEmpty {
                    Hint("No prices published ahead yet.")
                } else {
                    strip(summary, unit: unit)
                        .frame(height: 64)
                    if let mean = summary.meanMinor {
                        Hint("Dotted line: average ahead, \(PriceStrip.text(mean, prices.currency)) \(unit.label)", tone: Theme.fgMuted)
                    }
                }
            } else {
                HStack {
                    Text("Price to import").font(.headline)
                    Spacer()
                    Text(unit.perKwh).font(.caption).foregroundStyle(Theme.fgMuted)
                }
                full(unit: unit)
                    .frame(height: 180)
            }
        }
    }

    private func strip(_ summary: PriceStrip.Summary, unit: PriceUnits.Unit) -> some View {
        Chart {
            ForEach(summary.bars) { bar in
                BarMark(
                    xStart: .value("From", date(bar.startMs)),
                    xEnd: .value("To", date(bar.endMs)),
                    y: .value("Price", PriceUnits.display(bar.minor, prices.currency))
                )
                .foregroundStyle(color(bar.tone))
                .opacity(bar.current ? 1 : 0.8)
            }
            if let mean = summary.meanMinor {
                RuleMark(y: .value("Average", PriceUnits.display(mean, prices.currency)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel("Upcoming prices as bars from zero. The dotted line marks the average ahead.")
    }

    private func full(unit: PriceUnits.Unit) -> some View {
        Chart {
            ForEach(prices.slots) { slot in
                let past = slot.startMs + slot.durationMs <= nowMs
                let current = nowMs >= slot.startMs && nowMs < slot.startMs + slot.durationMs
                BarMark(
                    xStart: .value("From", date(slot.startMs)),
                    xEnd: .value("To", date(slot.startMs + slot.durationMs)),
                    y: .value("Price", PriceUnits.display(slot.totalMinor, prices.currency))
                )
                .foregroundStyle(current ? Theme.accent : past ? Theme.fgMuted.opacity(0.35) : Theme.storage)
            }
            RuleMark(x: .value("Now", date(nowMs)))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading) {
                    Text("now").font(Theme.number(10)).foregroundStyle(Theme.accent)
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel()
            }
        }
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    private func color(_ tone: PriceStrip.Tone) -> Color {
        switch tone {
        case .dear: return Theme.importing
        case .cheap: return Theme.exporting
        case .flat: return Theme.fgMuted
        case .negative: return Theme.generation
        }
    }
}
