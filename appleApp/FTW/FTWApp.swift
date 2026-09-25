import FTWKit
import SwiftUI

@main
struct FTWApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let network: NetworkWatch
    static let mainWindow = "main"

    init() {
        let store = KeychainStore()
        let files = SealedFiles(directory: SealedFiles.defaultDirectory(), store: store)
        let model = AppModel(store: store, files: files, passkeys: Passkeys(), build: AppInfo.build, ua: AppInfo.userAgent)
        // A paired phone paints its cached home before anything else runs.
        model.launch()
        _app = State(initialValue: model)
        network = NetworkWatch { [weak model] in model?.networkOnline() }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            RootView(app: app)
                .onOpenURL { app.offer($0.absoluteString) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    app.setVisible(AppInfo.isVisible(phase))
                }
        }
        #if os(macOS)
        .defaultSize(width: 520, height: 820)
        #endif

        #if os(macOS)
        MenuBarExtra {
            GlanceView(app: app)
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuBarExtraStyle(.window)
        #endif
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

    static var userAgent: String {
        #if os(iOS)
        return "FTW iOS \(version)"
        #else
        return "FTW macOS \(version)"
        #endif
    }

    /// A phone in the background is not looked at. A Mac window behind
    /// another app still is.
    static func isVisible(_ phase: ScenePhase) -> Bool {
        #if os(iOS)
        return phase == .active
        #else
        return phase != .background
        #endif
    }
}
