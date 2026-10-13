import FTWKit
import SwiftUI
#if targetEnvironment(simulator)
import PhotosUI
#endif

/// Pairing, the first thing anyone sees. Scan, then Face ID. Everything that
/// can fail does so before the passkey prompt.
///
/// A large title the system collapses as the page scrolls, the words above,
/// and one prominent action pinned at the foot, so it is in reach on every
/// iPhone whatever the text size.
struct PairView: View {
    let app: AppModel
    @State private var model: PairModel
    #if targetEnvironment(simulator)
    @State private var picture: PhotosPickerItem?
    #endif

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: PairModel(app: app))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    AboutLink(app: app)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.surface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) { actions }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 520)
                    .animation(Theme.spring, value: model.stage)
            }
        }
    }

    /// A screen reached from a home says what this phone cannot do.
    private var problem: String? { app.recovering ? app.connectHelp : nil }
    private var canDismiss: Bool { app.recovering }

    private var title: String {
        switch model.stage {
        case .scanning: return L("Scan the pairing QR")
        case .pairing: return L("Securing this phone")
        case .demoing: return L("Starting the demo")
        case .intro:
            if model.offeredFingerprint != nil {
                return model.known != nil ? L("Connect to a different box?") : L("Connect this box?")
            }
            return problem != nil ? L("Get this phone back in") : model.canOpen ? L("Welcome back") : L("Connect FTW")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .scanning:
            QRScanner { code in Task { await model.pair(code) } }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.accentFill, lineWidth: 3).padding(60))
            Hint(L("In your box's local dashboard, open Settings → FTW app. Hold the pairing QR inside the frame."))

        case .pairing:
            Text(L("Confirm with Face ID or Touch ID if your phone asks."))
            ProgressView()

        case .demoing:
            Text(L("Loading a simulated home."))
            ProgressView()

        case .intro:
            if let fingerprint = model.offeredFingerprint {
                offer(fingerprint)
            } else {
                intro
            }
        }
    }

    /// The pinned foot: the one prominent action for this step, and its
    /// quiet way out.
    @ViewBuilder private var actions: some View {
        switch model.stage {
        case .scanning, .pairing:
            Button(L("Cancel")) { model.cancel() }
                .buttonStyle(.glass)
                .controlSize(.large)
        case .demoing:
            EmptyView()
        case .intro:
            if let fingerprint = model.offeredFingerprint {
                prominent(model.known != nil ? NodeWords.format("Connect %@", fingerprint) : L("Connect this box")) {
                    Task { await model.acceptOffer() }
                }
                Button(L("Not now")) { model.declineOffer() }.buttonStyle(.quiet)
            } else if model.canOpen, let known = model.known {
                prominent(NodeWords.format("Open %@", known.label)) { model.openKnown() }
                Button(L("Scan a new pairing QR")) { model.stage = .scanning }.buttonStyle(.quiet)
            } else {
                prominent(L("Scan the pairing QR")) { model.stage = .scanning }
                if canDismiss {
                    Button(L("Not now")) { model.dismiss() }.buttonStyle(.quiet)
                }
            }
        }
    }

    private func prominent(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.accentFill)
        .foregroundStyle(Theme.onAccent)
        .accessibilityIdentifier("pair.primary")
    }

    /// A link that arrived from outside, shown with the box it names before
    /// anything trusts it.
    @ViewBuilder private func offer(_ fingerprint: String) -> some View {
        if let known = model.known {
            mono(NodeWords.format("This link points at box %@. Connecting it replaces %@ as the home this app shows and controls. Your key for %@ stays on this phone.", fingerprint, known.label, known.label), fingerprint)
        } else {
            mono(NodeWords.format("This link points at box %@. Only continue if you just opened Settings → FTW app and chose Show pairing code in this box's local dashboard.", fingerprint), fingerprint)
        }
        if let message = model.message { Problem(message) }
    }

    /// A sentence with the box's fingerprint set in mono, so it reads
    /// character by character against the box's own page.
    private func mono(_ sentence: String, _ code: String) -> Text {
        var text = AttributedString(sentence)
        if let range = text.range(of: code) { text[range].font = Theme.mono(.callout, weight: .semibold) }
        return Text(text)
    }

    @ViewBuilder private var intro: some View {
        if let problem {
            Text(problem)
        } else if model.canOpen {
            Text(L("Your key is still on this phone. Nothing to set up again."))
        } else {
            Text(app.canDemo ? L("Connect your own box, or try a live simulated home first.") : L("Connect your own box."))
        }
        if let message = model.message { Problem(message) }

        if model.canOpen {
            Hint(L("Use a new QR from Settings → FTW app if this key no longer works."))
        } else {
            setup
        }

        if problem == nil, !canDismiss, !model.canOpen, app.canDemo {
            demoOffer
        }
    }

    private var demoOffer: some View {
        Card {
            Kicker(L("Interactive demo"))
            Text(L("See a home running")).font(.title3.weight(.semibold))
            Text(L("Explore live solar, battery, grid, prices and EV charging. The data is simulated and nothing is saved."))
                .foregroundStyle(Theme.fgDim)
            Button(L("Try the live demo")) { model.tryDemo() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("pair.demo")
        }
    }

    /// Where the QR is, in one line; the steps behind "How?".
    private var setup: some View {
        Card {
            Text(L("Connect your own box")).font(.title3.weight(.semibold))
            Text(L("At home, open your box's FTW dashboard, then Settings → FTW app → Show pairing code."))
                .font(.callout)
            DisclosureGroup(L("How?")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("1. Open your box's local FTW dashboard while on your home network."))
                    Text(L("2. Go to Settings → FTW app."))
                    Text(L("3. Choose Show pairing code, then scan the QR here."))
                    Hint(L("The QR code is inside FTW Settings. It is not printed on the Raspberry Pi or its case."))
                    Hint(L("Next, your phone asks for Face ID or Touch ID to protect your FTW key. There is no FTW account or password. If this phone loses its key, a new Settings QR is the way back."))
                    Hint(L("Can't see Show pairing code? Turn on Let the FTW app connect to this box, save, and restart the box first."))
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.footnote.weight(.medium))
            #if targetEnvironment(simulator)
            // The simulator has no camera. A screenshot of the QR in Photos
            // takes the same path as a scan.
            PhotosPicker(L("Choose a picture of the QR"), selection: $picture, matching: .images)
                .buttonStyle(.quiet)
                .onChange(of: picture) { _, item in read(item) }
            #endif
        }
    }
}

#if targetEnvironment(simulator)
extension PairView {
    private func read(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            picture = nil
            if let link = data.flatMap(PairingImage.link(in:)) {
                await model.pair(link)
            } else {
                model.noCodeFound()
            }
        }
    }
}
#endif

struct Title: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Theme.fg)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Problem: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.alarm)
            .fixedSize(horizontal: false, vertical: true)
    }
}
