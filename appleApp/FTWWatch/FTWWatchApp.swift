import FTWShared
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct FTWWatchApp: App {
    @State private var model: WatchModel
    @Environment(\.scenePhase) private var phase

    init() {
        // The model starts before the first frame, so a context the phone
        // left earlier paints at once.
        let model = WatchModel.make()
        model.start()
        CloudRefresh.model = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            WatchRoot(model: model)
                .onChange(of: phase, initial: true) { _, phase in
                    // On screen: ask the phone for Now. Away: let it go, so
                    // the phone closes its session and frees a relay stream.
                    if phase == .active {
                        model.look()
                    } else {
                        model.away()
                        CloudRefresh.schedule()
                    }
                }
        }
        // A complication's refresh, when watchOS grants one: one read of
        // FTW Cloud, then the next asked for.
        .backgroundTask(.appRefresh(CloudRefresh.id)) {
            await CloudRefresh.run()
        }
        // The phone sent tomorrow's prices or a new context while the app
        // slept. Stay up until WatchConnectivity has handed it all over.
        .backgroundTask(.watchConnectivity) {
            await ContentPending.drained()
        }
    }
}

/// The complications' own reads, with no phone near. watchOS wakes the app
/// for one about as often as asked while a complication of it is on the
/// face, and less once its budget runs low; each wake reads FTW Cloud once
/// and asks for the next. No loop of its own.
@MainActor
enum CloudRefresh {
    static let id = "energy.ftw.cloud-read"
    static let every: TimeInterval = 30 * 60
    static weak var model: WatchModel?

    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date(timeIntervalSinceNow: every), userInfo: id as NSString) { @Sendable error in
            if let error { WatchModel.log.notice("no background read scheduled: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func run() async {
        await model?.refresh()
        schedule()
    }
}

/// Waits until WatchConnectivity holds nothing more for this app, by
/// watching the session's own flag rather than asking again and again.
enum ContentPending {
    static func drained() async {
        let session = WCSession.default
        if session.activationState != .activated {
            session.activate()
        }
        guard session.hasContentPending else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once(done)
            let watch = session.observe(\.hasContentPending, options: [.initial, .new]) { s, _ in
                if !s.hasContentPending { once.fire() }
            }
            once.keep(watch)
        }
    }

    /// Resumes once, and holds the observation until it has.
    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var observation: NSKeyValueObservation?
        private let lock = NSLock()

        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }

        func keep(_ o: NSKeyValueObservation) {
            lock.withLock { if continuation == nil { o.invalidate() } else { observation = o } }
        }

        func fire() {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                defer { continuation = nil; observation?.invalidate(); observation = nil }
                return continuation
            }
            c?.resume()
        }
    }
}
