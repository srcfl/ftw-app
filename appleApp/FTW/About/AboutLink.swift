import FTWKit
import SwiftUI

/// The way to Source & licenses and to removing this phone, at the foot of
/// Now and of pairing. The license asks that its text and the source offer
/// be reachable from inside the app, and App Review asks the same of
/// removing what the app set up.
struct AboutLink: View {
    let app: AppModel
    @State private var open: AboutView.Start?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 20))
        VStack(spacing: 6) {
            stack {
                Button(AboutWords.text("Source & licenses")) { open = .about }
                if AboutView.canRemove(app) {
                    Button(AboutWords.text("Remove this phone")) { open = .remove }
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
            Text(verbatim: "FTW \(BuildSource.bundled.versionText)")
                .font(.caption)
                .foregroundStyle(Theme.fgMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .sheet(item: $open) { start in
            AboutView(app: app, start: start)
        }
        #if DEBUG
        // For screenshots: `-FTWAbout about`, `remove` or a file name such
        // as `LICENSE` opens Source & licenses there.
        .task {
            if let name = UserDefaults.standard.string(forKey: "FTWAbout") { open = AboutView.Start(name) }
        }
        #endif
    }
}

extension BuildSource {
    /// This build, as its bundle records it. The "Record the source revision"
    /// phase writes the commit; CI sets FTW_SOURCE_REVISION to GITHUB_SHA.
    static let bundled = BuildSource(
        version: AppInfo.version,
        build: AppInfo.buildNumber,
        recorded: Bundle.main.url(forResource: "REVISION", withExtension: nil, subdirectory: "Licenses")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    )
}
