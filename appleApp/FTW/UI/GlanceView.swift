#if os(macOS)
import FTWKit
import SwiftUI

/// The Mac's glance from the menu bar: the band, the sentence and the four
/// figures, without opening a window.
struct GlanceView: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let site = app.site {
                FreshnessBandView(band: site.freshness(noCarrier: app.connectHelp != nil), frameAtMs: site.lastFrameAtMs)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if !site.session.fields.isEmpty {
                    Text(site.explanation.headline)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        figure("Grid", Contract.FID.gridW, site) { $0 > 0 ? "drawing" : "exporting" }
                        figure("Solar", Contract.FID.pvW, site) { _ in "producing" }
                        figure("Battery", Contract.FID.batteryW, site) { $0 > 0 ? "charging" : "supplying" }
                        figure("Home", Contract.FID.loadW, site) { _ in "using" }
                    }
                } else {
                    Text("Nothing from your box yet.").foregroundStyle(Theme.fgDim)
                }
            } else {
                Text("No home is paired on this Mac.").foregroundStyle(Theme.fgDim)
            }
            Divider()
            HStack {
                Button("Open FTW") {
                    NSApplication.shared.activate()
                    if let window = NSApplication.shared.windows.first(where: \.canBecomeMain) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: FTWApp.mainWindow)
                    }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func figure(_ label: String, _ fid: Int, _ site: SiteModel, words: (Double) -> String) -> some View {
        let reading = site.session.fields[fid].map { fid == Contract.FID.pvW ? abs($0) : $0 }
        let value = reading.map(PowerFormat.text) ?? "—"
        let word = reading.map { PowerFormat.direction($0) == .idle ? "idle" : words($0) } ?? ""
        return GridRow {
            Text(label).foregroundStyle(Theme.fgDim)
            Text(value).font(Theme.number(14))
            Text(word).foregroundStyle(Theme.fgMuted)
        }
    }
}
#endif
