import FTWKit
import SwiftUI

/// The colour of a price against the hours around it: green below the
/// average ahead, red above, grey near it, yellow below zero.
enum PriceBars {
    static func color(_ tone: PriceStrip.Tone) -> Color {
        switch tone {
        case .dear: return Theme.importing
        case .cheap: return Theme.exporting
        case .flat: return Theme.fgMuted
        case .negative: return Theme.generation
        }
    }
}
