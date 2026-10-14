import FTWShared
import SwiftUI
import WatchConnectivity

@main
struct FTWWatchApp: App {
    @State private var model: WatchModel
    @Environment(\.scenePhase) private var phase

    init() {
        // The model starts before the first frame, so a context the phone
        // left earlier paints at once.
        let model = WatchModel.make()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            WatchRoot(model: model)
                .onChange(of: phase, initial: true) { _, phase in
                    // On screen: ask the phone for Now. Away: let it go, so
                    // the phone closes its session and frees a relay stream.
                    if phase == .active { model.look() } else { model.away() }
                }
        }
        // The phone sent tomorrow's prices or a new context while the app
        // slept. Stay up until WatchConnectivity has handed it all over.
        .backgroundTask(.watchConnectivity) {
            await ContentPending.drained()
        }
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
