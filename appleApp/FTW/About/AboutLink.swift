import FTWKit
import SwiftUI

/// The way to Source & licenses, the privacy policy and removing this phone,
/// at the foot of Now and of pairing. The license asks that its text and the
/// source offer be reachable from inside the app; App Review asks the same
/// of the privacy policy (5.1.1(i)) and of removing what the app set up.
struct AboutLink: View {
    let app: AppModel
    @State private var open: AboutView.Start?

    var body: some View {
        // One line while it fits, with the version on it, one link to a
        // line when it does not: a foot of one row, so the pairing page
        // fits over its bar at the default size and nothing sits half
        // under it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                links
                version
            }
            VStack(spacing: 8) {
                links
                version
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.accent)
        .buttonStyle(.plain)
        // A 44 pt target for each, without a taller line of text.
        .frame(minHeight: 44)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        // The foot of the page: never larger than the drawing above it.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
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

    private var version: some View {
        Text(verbatim: "FTW \(BuildSource.bundled.versionText)")
            .font(.caption)
            .foregroundStyle(Theme.fgMuted)
    }

    @ViewBuilder private var links: some View {
        Button(AboutWords.text("Source & licenses")) { open = .about }
        Link(AboutWords.text("Privacy"), destination: Origin.privacyURL())
        if AboutView.canRemove(app) {
            Button(AboutWords.text("Remove this phone")) { open = .remove }
        }
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
