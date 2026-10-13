import FTWKit

/// How long from the process starting to each first thing on screen,
/// logged once each and marked for Instruments: the first frame, the first
/// content, and (from SiteModel) the first live reading. Read them with:
///
///     xcrun simctl spawn <udid> log show --last 2m \
///       --predicate 'subsystem == "energy.ftw.app" AND category == "launch"'
@MainActor
enum LaunchClock {
    /// Once per event: the first frame, the first content.
    static func mark(_ event: StaticString) {
        ProcessClock.markOnce(event)
    }
}
