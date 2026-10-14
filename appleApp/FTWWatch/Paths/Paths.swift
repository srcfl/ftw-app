import FTWShared

// Where the watch reads the home from, and where its commands go. Two
// seams, so the watch can stand on its own later without its screens
// knowing. Today one path does both: `PhonePath`, through the iPhone over
// WatchConnectivity. Later, with the phone away on LTE:
//
// - `CloudReadPath` reads Now, the plan and the prices from FTW Cloud over
//   HTTPS, signed by the box.
// - `DirectPath` sends commands to the box through the relay's exchange
//   (ADR 0009), with the watch's own key (`WatchIdentity`).
//
// Neither is built yet. The watch already makes its own `cmdId`, so a
// command tried both ways runs once.

/// What a path tells the watch.
enum PathEvent: Sendable {
    /// Everything the watch shows, replaced whole.
    case context(WatchContext)
    /// A live frame of Now, or a step of a command's receipt.
    case news(WatchNews)
    /// Whether commands can leave now.
    case canSend(Bool)
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
}

/// Where commands go. The path sends intent; the box decides, and every
/// mark of the receipt comes back from the box's answers.
@MainActor
protocol CommandPath: AnyObject {
    func send(_ command: WatchCommand)
}
