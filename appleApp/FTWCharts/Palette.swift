import FTWShared
import SwiftUI

/// FTW's palette and type on the phone, shared by the app and the widgets.
/// Every value lives in `Theme.xcassets` beside this file, one colour set
/// per role with its dark variant, authored in Display P3, so the system
/// switches them and both targets read the same source.
///
/// Light means live: only a reading the box has confirmed live may glow or
/// move. Colour is energy and the interface is ink. Each energy kind has
/// one hue, the battery two (gives and stores). Live and alarm are states,
/// never levels.
enum Theme {
    /// Every screen, and the body of every sheet: a blue-black void in dark.
    static let ground = Color("ftw.ground")
    /// Sheets, menus and list rows.
    static let raised = Color("ftw.raised")
    /// Only where two lists meet.
    static let hairline = Color("ftw.hairline")

    /// Figures, chrome, the system tint and the home.
    static let ink = Color("ftw.ink")
    /// Units, words and second lines.
    static let ink2 = Color("ftw.ink2")
    /// Axes, footers and idle strokes. Increase Contrast makes it ink2.
    static let ink3 = Color("ftw.ink3")

    /// The sun.
    static let solar = Color("ftw.solar")
    /// The battery giving power.
    static let gives = Color("ftw.gives")
    /// The battery storing power, and its level.
    static let stores = Color("ftw.stores")
    /// The grid, both ways. The side of zero and the word say buying or
    /// selling.
    static let grid = Color("ftw.grid")
    /// The car.
    static let car = Color("ftw.car")

    /// A state: live, or confirmed.
    static let live = Color("ftw.live")
    /// A state: dispatch blocked, refused, failed.
    static let alarm = Color("ftw.alarm")

    /// A figure: SF Pro with even digits, so a value that changes does not
    /// shift the line, and with no slashed zero or wide decimal gap.
    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// The terminal layer only: status line, kickers, axis labels, footers,
    /// receipts and the scrub tag. Everything else is SF Pro.
    static func mono(_ style: Font.TextStyle = .caption2, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// A price by its level against the hours around it, in ink: the
    /// dearer, the stronger (0.32, 0.50, 0.80). No red and no green: a price
    /// is a level, not a state.
    static func price(_ tone: PriceStrip.Tone) -> Color {
        switch tone {
        case .cheap, .negative: return ink.opacity(0.32)
        case .flat: return ink.opacity(0.5)
        case .dear: return ink.opacity(0.8)
        }
    }

    /// A plan's marks, wherever it is drawn: their hue at this strength,
    /// never the full one that says live. 3:1 or more on the ground in both
    /// themes; nearer full with Increase Contrast. Words keep full strength,
    /// so they stay easy to read.
    static func plan(_ contrast: ColorSchemeContrast) -> Double { contrast == .increased ? 0.9 : 0.75 }
    /// An old plan's marks, or one the box could not make: ink3, weaker
    /// than a plan's.
    static let oldPlan = ink3.opacity(0.45)

    /// One colour as it looks in one scheme, for a place that draws in a
    /// fixed one whatever the phone's: the Dynamic Island is always dark,
    /// and Control Center draws an on switch's glyph on white.
    static func fixed(_ color: Color, _ scheme: ColorScheme) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return Color(color.resolve(in: environment))
    }
}
