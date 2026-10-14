import BackgroundTasks
import FTWDemo
import FTWKit
import os
import SwiftUI
import WidgetKit

@main
struct FTWApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// Only for what SwiftUI has no door for: the push token, and buttons
    /// on a notification. It starts after `init`, so the runner is there.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let network: NetworkWatch

    init() {
        let store = KeychainStore()
        let files = SealedFiles(directory: SealedFiles.defaultDirectory(), store: store)
        let model = AppModel(
            store: store,
            files: files,
            // What the widgets read. Nil only in a build without the App
            // Group entitlement, and then the app works without widgets.
            shared: AppGroupFiles.shared(),
            // The watch gets the same records the widgets just got.
            sharedWritten: {
                WidgetCenter.shared.reloadAllTimelines()
                WatchBridge.shared.cacheWritten()
            },
            passkeys: Passkeys(),
            build: AppInfo.build,
            ua: AppInfo.userAgent,
            // App Review and anyone without a box can try a simulated home.
            demo: SimulatedBox.loopback
        )
        // Siri, the Control and the Live Activity reach the box through the
        // app, and Charge now starts its Live Activity wherever it is pressed.
        IntentRunner.install(model)
        // The Apple Watch reads through this phone and sends its commands
        // here, over the same runner.
        if let runner = IntentRunner.shared { WatchBridge.shared.install(model, runner: runner) }
        // A paired phone paints its cached home before anything else runs.
        model.launch()
        #if DEBUG
        // For screenshots: `-FTWDemo YES` opens the simulated home, and
        // `-FTWDemoWidgets YES` lets it leave its records for the widgets.
        // `-FTWDemoCache YES` lets it keep its sealed cache like a paired
        // home, to record and time a cold start.
        model.demoSharesWidgets = UserDefaults.standard.bool(forKey: "FTWDemoWidgets")
        model.demoKeepsCache = UserDefaults.standard.bool(forKey: "FTWDemoCache")
        if UserDefaults.standard.bool(forKey: "FTWDemo") { model.startDemo() }
        // For end-to-end tests: `-FTWPairLink <url>` offers a pairing link
        // as a scanned QR would, where the simulator has no camera.
        if let link = UserDefaults.standard.string(forKey: "FTWPairLink") { model.offer(link) }
        #endif
        _app = State(initialValue: model)
        network = NetworkWatch { [weak model] in model?.networkOnline() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                // A pairing QR scanned with the iOS camera arrives as a
                // universal link to https://app.ftw.energy/p#…, and takes the
                // same path as any other pairing link.
                .onOpenURL { app.offer($0.absoluteString) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { app.offer(url.absoluteString) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Inactive is a glance at Control Center or the app
                    // switcher, or the way back from the background: the
                    // stream keeps 1 Hz, and a return dials here, not at
                    // active. Only the background closes the session.
                    PricesInBackground.inBackground = phase == .background
                    switch phase {
                    case .background:
                        app.setVisible(false)
                        app.suspend()
                        Task { await PricesInBackground.schedule(app) }
                    case .inactive:
                        app.glance()
                    default:
                        app.setVisible(true)
                    }
                }
        }
        .backgroundTask(.appRefresh(PricesInBackground.id)) { [app] in
            await PricesInBackground.run(app)
        }
    }
}

/// Tomorrow's prices for the widgets without opening the app. iOS wakes the
/// app shortly after 13:05 if it allows it at all; the app opens a session,
/// asks for prices, leaves them in the App Group and closes again. No silent
/// push and no server: when iOS does not wake the app, the widgets wait for
/// the next time it is opened.
@MainActor
enum PricesInBackground {
    /// Listed under BGTaskSchedulerPermittedIdentifiers in FTW-Info.plist.
    static let id = "energy.ftw.app.prices"
    static let log = Logger(subsystem: "energy.ftw.app", category: "widgets")
    /// Set from the scene phase. A cold launch for this task has no scene,
    /// so it starts in the background.
    static var inBackground = true

    static func schedule(_ app: AppModel) async {
        guard let site = app.site, site.siteId != nil, !app.isDemo else { return }
        let pricesEndMs = await site.sharedPricesEndMs()
        let nowMs = Date.now.timeIntervalSince1970 * 1000
        let at = Date(timeIntervalSince1970: PriceRefresh.next(afterMs: nowMs, pricesEndMs: pricesEndMs) / 1000)
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = at
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("background prices asked for after \(at.formatted(date: .abbreviated, time: .shortened), privacy: .public)")
        } catch {
            // The simulator, Background App Refresh turned off, or Low Power
            // Mode. The widgets then wait for the app to be opened.
            log.notice("background prices not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func run(_ app: AppModel) async {
        guard let site = app.site, site.siteId != nil, !app.isDemo else { return }
        log.info("background prices: woken")
        // A new carrier if the last one was closed, or a fresh stream.
        await app.refresh()
        let prices = await site.refreshSharedPrices()
        log.info("background prices: \(prices == nil ? "nothing written" : "\(prices!.slots.count) slots written", privacy: .public)")
        // Someone may have opened the app meanwhile; their session stays.
        if inBackground { app.suspend() }
        await schedule(app)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// What the box records about this app in its hello.
    static var build: String { "\(version)+\(buildNumber)" }

    static var userAgent: String { "FTW iOS \(version)" }
}
