import SwiftUI

/// How the app looks: dark unless the person picks light or the iPhone's
/// own setting. Dark is the default because light means live: the glow on
/// a live reading only shows on the dark ground (Fredrik, 26 October 2026).
/// The widgets and the watch keep the system's look.
enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system

    /// Where the choice is kept, on this phone only. A launch argument
    /// `-appearance light|dark|system` stands in for it, for screenshots
    /// and tests.
    static let key = "appearance"

    /// What the app opens in until the person picks.
    static let standard = Appearance.dark

    var id: String { rawValue }

    /// The scheme the window takes; nil follows the iPhone.
    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .dark: L("Dark")
        case .light: L("Light")
        case .system: L("Match iPhone")
        }
    }
}
