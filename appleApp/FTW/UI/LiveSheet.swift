import Charts
import FTWKit
import SwiftUI

/// Which bubble was tapped. Everything else follows from it.
enum LiveRole: String, Identifiable {
    case grid, pv, battery, load
    var id: String { rawValue }
}

/// One part of the house over the last two minutes. The line moves on news
/// and freezes on silence: a repeated cache value moves nothing.
struct LiveSheet: View {
    let site: SiteModel
    let role: LiveRole
    let fields: [Int: Double]
    @Environment(\.dismiss) private var dismiss

    private struct Spec {
        let title: String
        let fid: Int
        let signed: Bool
        let words: (Double) -> String
    }

    private var spec: Spec {
        switch role {
        case .grid: return Spec(title: "Grid", fid: Contract.FID.gridW, signed: true) { abs($0) < 20 ? "balanced" : $0 > 0 ? "drawing from the grid" : "exporting to the grid" }
        case .pv: return Spec(title: "Solar", fid: Contract.FID.pvW, signed: false) { abs($0) < 20 ? "not producing" : "producing" }
        case .battery: return Spec(title: "Battery", fid: Contract.FID.batteryW, signed: true) { abs($0) < 20 ? "resting" : $0 > 0 ? "charging" : "discharging" }
        case .load: return Spec(title: "Home", fid: Contract.FID.loadW, signed: false) { _ in "used by the house" }
        }
    }

    var body: some View {
        let spec = spec
        let raw = fields[spec.fid]
        let live = site.isLive
        let color = Theme.color(Flow.tone(Flow.Role(rawValue: role.rawValue) ?? .load, raw))
        // Reading the stream's clock ties this view to every new frame.
        let _ = site.session.uptimeMs
        let points = site.recentField(spec.fid).map { (t: $0.t, v: spec.signed ? $0.v : abs($0.v)) }
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let raw {
                    let parts = PowerFormat.parts(spec.signed ? raw : abs(raw))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parts.text).font(Theme.number(44, weight: .bold)).foregroundStyle(color)
                        Text(parts.unit).font(.title3).foregroundStyle(color)
                        if role == .battery, let soc = fields[Contract.FID.batterySoc] {
                            Text("\(PowerFormat.soc(soc))%").font(Theme.number(20)).foregroundStyle(Theme.fgDim)
                        }
                    }
                    Text(spec.words(spec.signed ? raw : abs(raw)) + (live ? "" : " · last known"))
                        .foregroundStyle(Theme.fgDim)
                    chart(points, color: color)
                        .frame(height: 200)
                    Hint("last two minutes", tone: Theme.fgMuted)
                } else {
                    Hint("No reading from your box yet.")
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle(spec.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func chart(_ points: [(t: Double, v: Double)], color: Color) -> some View {
        let end = site.nowMs
        return Chart {
            ForEach(points, id: \.t) { p in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: p.t / 1000)), y: .value("Watts", p.v))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            if spec.signed {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: (end - 120_000) / 1000)...Date(timeIntervalSince1970: end / 1000))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let w = value.as(Double.self) { Text(PowerFormat.scale(w)).font(Theme.number(10, weight: .regular)) }
                }
            }
        }
    }
}
