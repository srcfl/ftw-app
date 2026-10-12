import Darwin
import os

/// How long from the process starting to each first thing on screen,
/// logged once each and marked for Instruments. Read them with:
///
///     xcrun simctl spawn <udid> log show --last 2m \
///       --predicate 'subsystem == "energy.ftw.app" AND category == "launch"'
@MainActor
enum LaunchClock {
    static let log = Logger(subsystem: "energy.ftw.app", category: "launch")
    static let signposter = OSSignposter(logger: log)
    private static var seen: Set<String> = []

    /// Once per event: the first frame, the first content, the stream.
    static func mark(_ event: StaticString) {
        let name = "\(event)"
        guard seen.insert(name).inserted else { return }
        signposter.emitEvent(event)
        if let ms = sinceProcessStartMs() {
            log.notice("\(name, privacy: .public) \(Int(ms.rounded()), privacy: .public) ms after process start")
        }
    }

    /// The kernel's record of when this process started.
    static func sinceProcessStartMs() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) * 1000 + Double(now.tv_usec - start.tv_usec) / 1000
    }
}
