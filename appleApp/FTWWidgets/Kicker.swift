import SwiftUI

/// A widget's kicker, `PRIS NU` or `NÄTET I DAG`: SF Mono caps in ink2,
/// the terminal layer's label over a figure.
struct Kicker: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
