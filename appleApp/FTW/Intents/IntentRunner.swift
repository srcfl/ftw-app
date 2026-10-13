import AppIntents
import FTWKit
import FTWShared
import os

/// Runs what a Control, Siri or the Live Activity asks for, inside the app.
///
/// An intent can wake the app in the background. `FTWApp.init` has then
/// already started connecting; this waits for that stream, sends the
/// command exactly as the car view does, and closes the session again if
/// nobody is looking, because an open socket holds one of the four streams
/// the relay allows a home.
@MainActor
final class IntentRunner: CommandRunner {
    static let log = Logger(subsystem: "energy.ftw.app", category: "intents")

    /// The runner `FTWApp` installed. The intents that only the app has
    /// (`CarStatusIntent`, its card) reach it here.
    private(set) static var shared: IntentRunner?

    let app: AppModel
    /// Intents running now. The last one to finish closes the session.
    private var running = 0

    init(app: AppModel) {
        self.app = app
    }

    /// Before the first home opens: the commands' runner, and the Live
    /// Activity that Charge now starts wherever it is pressed.
    static func install(_ app: AppModel) {
        let runner = IntentRunner(app: app)
        shared = runner
        CommandHost.install(runner)
        LoadpointsModel.sharedChargeNowHost = ChargeNowActivities()
        #if DEBUG
        // For screenshots: `-FTWDemo YES -FTWDemoChargeNow YES` presses
        // Charge now the way the Control does, once the demo streams.
        if UserDefaults.standard.bool(forKey: "FTWDemoChargeNow") {
            Task { _ = await runner.run(.chargeNow) }
        }
        #endif
    }

    nonisolated func run(_ command: RemoteCommand) async -> RemoteOutcome {
        await perform(command)
    }

    /// A notification's button: the same path, on the charger its event
    /// named.
    func run(_ command: RemoteCommand, loadpointID: String) async -> RemoteOutcome {
        await perform(command, loadpointID: loadpointID)
    }

    private func perform(_ command: RemoteCommand, loadpointID: String? = nil) async -> RemoteOutcome {
        guard let home = await begin() else { return RemoteOutcome(.failed, ChargeNowActivity.openAndRetry) }
        defer { end() }
        let started = ContinuousClock.now
        let out = await home.loadpoints.perform(command, loadpointID: loadpointID)
        Self.log.info("\(String(describing: command), privacy: .public) answered in \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 0), privacy: .public) ms")
        return out
    }

    /// "Is the car ready?": read the chargers and the plan, then answer. If
    /// the box is out of reach, the answer is the last one this phone had,
    /// dated.
    func answer() async -> CarAnswer? {
        let locked = DeviceLock.isLocked
        guard let home = await begin() else { return nil }
        defer { end() }
        if !(await home.loadpoints.refreshForAnswer()) {
            Self.log.notice("is the car ready: answered from what the phone had")
        }
        return home.loadpoints.answer(locked: locked)
    }

    /// The card's answer as it stands, without asking the box again: a
    /// button on the card has just read it.
    func currentAnswer() -> CarAnswer? {
        app.home?.loadpoints.answer(locked: DeviceLock.isLocked)
    }

    /// Whether `siteId` is the home this app opens. A command from a push
    /// goes only there; the demo never takes one, except in a debug build
    /// that seeded it as "demo" for a test.
    func opens(siteId: String) -> Bool {
        if app.isDemo {
            #if DEBUG
            return siteId == "demo"
            #else
            return false
            #endif
        }
        return (app.site?.siteId ?? app.sites.current()?.siteId) == siteId
    }

    /// The home, with a session on its way. A launch for an intent has
    /// already started connecting; an app whose session was closed in the
    /// background opens a new one.
    private func begin() async -> HomeModels? {
        if app.home == nil { app.launch() }
        guard let home = app.home else { return nil }
        running += 1
        if !app.isDemo, home.site.session.phase != .streaming {
            await app.refresh()
        }
        return home
    }

    private func end() {
        running -= 1
        guard running == 0, PricesInBackground.inBackground else { return }
        app.suspend()
    }
}

/// Whether the phone is locked, from the file system: a file protected
/// until unlock cannot be read or written while the phone is locked. No
/// UIKit. When in doubt it says locked, which only hides details.
enum DeviceLock {
    static var isLocked: Bool {
        let url = URL.applicationSupportDirectory.appending(path: "unlock-probe")
        if (try? Data(contentsOf: url)) != nil { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url, options: [.atomic, .completeFileProtection])
            return false
        } catch {
            return true
        }
    }
}
