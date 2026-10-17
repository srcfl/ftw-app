import FTWKit
import SwiftUI

/// Source & licenses: what this build is, where its exact source is, and
/// the license texts the build copied in from the repository root.
struct AboutView: View {
    enum Start: Hashable, Identifiable {
        case about, remove, statistics, cloudTerms
        case document(LicenseText.Document)

        var id: Self { self }

        init?(_ name: String) {
            switch name {
            case "about": self = .about
            case "remove": self = .remove
            case "statistics": self = .statistics
            case "cloud-terms": self = .cloudTerms
            default:
                guard let document = LicenseText.Document(rawValue: name) else { return nil }
                self = .document(document)
            }
        }
    }

    enum Route: Hashable {
        case document(LicenseText.Document)
        case remove
        case statistics
        case cloudTerms
    }

    let app: AppModel
    @State private var path: [Route]
    @State private var reviewConsent = CloudConsent()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 52
    private let source = BuildSource.bundled

    init(app: AppModel, start: Start = .about) {
        self.app = app
        switch start {
        case .about: _path = State(initialValue: [])
        case .remove: _path = State(initialValue: [.remove])
        case .statistics: _path = State(initialValue: [.statistics])
        case .cloudTerms: _path = State(initialValue: [.cloudTerms])
        case .document(let document): _path = State(initialValue: [.document(document)])
        }
    }

    /// A paired phone has something to remove. The demo has not, and its
    /// way out is Exit demo.
    static func canRemove(_ app: AppModel) -> Bool {
        !app.isDemo && (app.vault.isEnrolled || app.sites.current() != nil)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { header }

                Section {
                    LabeledContent(AboutWords.text("Version"), value: source.version)
                    LabeledContent(AboutWords.text("Build"), value: source.build)
                    LabeledContent(AboutWords.text("Commit")) {
                        Text(source.revisionText)
                            .font(source.isLocal ? .body : .body.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(AboutWords.text("This version"))
                } footer: {
                    if let note = source.localNote { Text(note) }
                }

                Section {
                    Link(destination: source.sourceURL) {
                        Label(source.isLocal ? AboutWords.text("Source code on GitHub") : AboutWords.text("Source code of this version"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: source.licenseURL) {
                        Label(source.isLocal ? AboutWords.text("License on GitHub") : AboutWords.text("License at this commit"), systemImage: "doc.text")
                    }
                } header: {
                    Text(AboutWords.text("Source code"))
                } footer: {
                    Text(AboutWords.text("FTW is free software. You may run, study, change and share it under the GNU AGPL v3 with the two additional permissions in LICENSE. The link gives the complete source of this exact version, at no charge."))
                }

                Section {
                    if !app.isDemo { NavigationLink { CloudSettingsView(app: app) } label: { Label(CloudWords.text("FTW Cloud"), systemImage: "cloud") } }
                    Link(destination: Origin.privacyURL()) {
                        Label(AboutWords.text("Privacy policy"), systemImage: "hand.raised")
                    }
                    Link(destination: Origin.supportURL()) {
                        Label(AboutWords.text("Support"), systemImage: "questionmark.circle")
                    }
                } header: {
                    Text(AboutWords.text("Privacy and support"))
                } footer: {
                    Text(app.site?.cloudOn == true ? CloudWords.text("With FTW Cloud on, Sourceful keeps a copy of your home's readings, signed by your box, to serve this app. Commands travel encrypted between this phone and your box, and Sourceful cannot read them.") : AboutWords.text("FTW collects nothing about you. Readings and commands travel encrypted between this phone and your box, and Sourceful cannot read them."))
                }

                Section {
                    ForEach(LicenseText.Document.allCases) { document in
                        NavigationLink(value: Route.document(document)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                Text(document.rawValue)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.fgMuted)
                            }
                        }
                    }
                } header: {
                    Text(AboutWords.text("Licenses"))
                } footer: {
                    Text(verbatim: "\(AboutWords.text("Third-party code")): \(AboutWords.text("None. FTW uses only Apple's own frameworks."))")
                }

                if Self.canRemove(app) {
                    Section(AboutWords.text("This phone")) {
                        NavigationLink(value: Route.remove) {
                            Text(AboutWords.text("Remove this phone"))
                                .foregroundStyle(Theme.alarm)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle(AboutWords.text("Source & licenses"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .tint(nil)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .document(let document):
                    LicenseView(document: document, source: source)
                case .statistics:
                    CloudSettingsView(app:app)
                case .cloudTerms:
                    CloudConsentView(app:app, consent:reviewConsent)
                case .remove:
                    RemovePhoneView(app: app) { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    /// The notices the AGPL asks an interactive program to show: who holds
    /// the copyright, that there is no warranty, and where the license is.
    private var header: some View {
        let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return stack {
            Image(systemName: "bolt.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: markSize, height: markSize)
                .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: markSize * 0.23, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("FTW").font(.title2.weight(.bold))
                Text(AboutWords.text("© 2026 Sourceful Labs AB and contributors."))
                    .font(.footnote)
                Text(AboutWords.text("There is no warranty, to the extent the law allows."))
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
