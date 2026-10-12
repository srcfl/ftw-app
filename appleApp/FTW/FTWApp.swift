import FTWDemo
import FTWKit
import SwiftUI
import WidgetKit

@main
struct FTWApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
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
            sharedWritten: { WidgetCenter.shared.reloadAllTimelines() },
            passkeys: Passkeys(),
            build: AppInfo.build,
            ua: AppInfo.userAgent,
            // App Review and anyone without a box can try a simulated home.
            demo: SimulatedBox.loopback
        )
        // A paired phone paints its cached home before anything else runs.
        model.launch()
        #if DEBUG
        // For screenshots: `-FTWDemo YES` opens the simulated home.
        if UserDefaults.standard.bool(forKey: "FTWDemo") { model.startDemo() }
        #endif
        _app = State(initialValue: model)
        network = NetworkWatch { [weak model] in model?.networkOnline() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .onOpenURL { app.offer($0.absoluteString) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Inactive is a glance at Control Center or the app
                    // switcher: slow the stream, keep the session. Only the
                    // background closes it.
                    app.setVisible(phase == .active)
                    if phase == .background { app.suspend() }
                }
        }
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
