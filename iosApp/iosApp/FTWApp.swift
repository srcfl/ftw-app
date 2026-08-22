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

    var body: some View {
        Group {
            if model.site != nil {
                NowView()
            } else {
                PairView()
            }
        }
    }
}
