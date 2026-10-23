import FTWShared

// Where the watch reads the home from, and where its commands go. Two
// seams, so the screens never know which path carried what:
//
// - `PhonePath`, through the iPhone over WatchConnectivity.
// - `CloudPath`, the watch on its own through FTW Cloud: Now, the car and
//   the prices from FTW Cloud's copy, signed by the box, and commands
//   through the box's exchange, with the watch's own key (`WatchIdentity`,
//   ADR 0009). The plan stays the phone's: the box does not send it there.
//
// `PathChooser` puts the two behind one face. The watch makes its own
// `cmdId`, so a command tried both ways runs once.

/// What a path tells the watch.
enum PathEvent: Sendable {
    /// Everything the watch shows, replaced whole.
    case context(WatchContext)
    /// A live frame of Now, or a step of a command's receipt.
    case news(WatchNews)
    /// Whether commands can leave now.
    case canSend(Bool)
    /// Whether the phone can be reached, for what only the phone may send.
    case phoneReachable(Bool)
    /// A command never left: nothing reached the box.
    case notSent(commandID: String)
}

typealias PathSink = @MainActor (PathEvent) -> Void

/// Where the home comes from.
@MainActor
protocol ReadPath: AnyObject {
    func start(_ sink: @escaping PathSink)
    /// The watch app is on screen: live frames are wanted.
    func look()
    /// It left the screen.
    func away()
    /// A read in the background, for a complication.
    func refresh() async
}

extension ReadPath {
    func refresh() async {}
}

/// Where commands go. The path sends intent; the box decides, and every
/// mark of the receipt comes back from the box's answers.
@MainActor
protocol CommandPath: AnyObject {
    func send(_ command: WatchCommand)
}

/// Milliseconds on a monotonic clock that runs on while the watch sleeps:
/// for a command's life and every wait, which the wall clock must not move.
enum WatchClock {
    private static let origin = ContinuousClock.now

    static func ms() -> Double {
        let d = origin.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
}
