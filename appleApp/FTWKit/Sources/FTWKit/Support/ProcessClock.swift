import Darwin
import os

/// How long since this process started, by the kernel's record, and a mark
/// logged once per process. The app's LaunchClock marks the first frame and
/// the first content with it; SiteModel marks the first live reading, so all
/// three count from the same moment. Read them with:
///
///     xcrun simctl spawn <udid> log show --last 2m \
///       --predicate 'subsystem == "energy.ftw.app" AND category == "launch"'
@MainActor
public enum ProcessClock {
    static let log = Logger(subsystem: "energy.ftw.app", category: "launch")
    private static var seen: Set<String> = []

    /// Once per name: a signpost event and a line with the time since start.
    public static func markOnce(_ event: StaticString) {
        let name = "\(event)"
        guard seen.insert(name).inserted else { return }
        OSSignposter(logger: log).emitEvent(event)
        if let ms = sinceStartMs() {
            log.notice("\(name, privacy: .public) \(Int(ms.rounded()), privacy: .public) ms after process start")
        }
    }

    /// The kernel's record of when this process started.
    public static func sinceStartMs() -> Double? {
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
