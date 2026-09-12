import SwiftUI
import Shared

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
        .safeAreaInset(edge: .bottom) {
            DisclosureGroup("Source & licenses") {
                Text("© 2026 Sourceful Labs AB and contributors. You may copy, modify and share under the license. No warranty to the extent permitted by law.")
                HStack {
                    Link("Source", destination: URL(string: SourceLicense.shared.sourceUrl)!)
                    Link("AGPLv3 + Energyplan permission", destination: URL(string: SourceLicense.shared.licenseUrl)!)
                }
            }
            .font(.caption)
            .padding(8)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.wake() }
        }
    }
}
