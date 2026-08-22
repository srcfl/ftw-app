import SwiftUI

@main
struct FTWApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.site != nil {
                NowView()
            } else {
                PairView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.wake() }
        }
    }
}
