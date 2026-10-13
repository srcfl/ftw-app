import SwiftUI

/// The grid widget's two colours, in one place. They are FTW's own roles:
/// `importing` for what the home buys and `exporting` for what it sells, as
/// `Theme.importing` and `Theme.exporting` (`ftw.importing` and
/// `ftw.exporting` in Theme.xcassets). The request asked for purple bars,
/// but purple is the car in FTW (`Theme.mobility`). A test holds these two
/// to the asset catalog.
enum GridColors {
    static let importing = Pair(0xCC243D, 0xFF6E74)
    static let exporting = Pair(0x009639, 0x5FD37F)

    /// The import bars, and the arrow on a day that bought more.
    static var bars: Pair { importing }
    /// The export curve, the arrow on a day that sold more, and money earned.
    static var curve: Pair { exporting }
}
