import FTWKit
import SwiftUI
#if targetEnvironment(simulator)
import PhotosUI
#endif

/// Pairing, the first thing anyone sees. Scan, then Face ID. Everything that
/// can fail does so before the passkey prompt.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                AboutLink(app: app)
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
    }

    /// A screen reached from a home says what this phone cannot do.
    private var problem: String? { app.recovering ? app.connectHelp : nil }
    private var canDismiss: Bool { app.recovering }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .scanning:
            QRScanner { code in Task { await model.pair(code) } }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.accent, lineWidth: 3).padding(60))
            Hint("In your box's local dashboard, open Settings → FTW app. Hold the pairing QR inside the frame.")
            Button("Cancel") { model.cancel() }.buttonStyle(.quiet)

        case .pairing:
            Title("Securing this phone")
            Text("Confirm with Face ID or Touch ID if your phone asks.")
            Button("Cancel") { model.cancel() }.buttonStyle(.quiet)

        case .demoing:
            Title("Starting the demo")
            Text("Loading a simulated home.")

        case .intro:
            if let fingerprint = model.offeredFingerprint {
                offer(fingerprint)
            } else {
                intro
            }
        }
    }

    /// A link that arrived from outside, shown with the box it names before
    /// anything trusts it.
    @ViewBuilder private func offer(_ fingerprint: String) -> some View {
        let known = model.known
        Title(known != nil ? "Connect to a different box?" : "Connect this box?")
        Group {
            if let known {
                Text("This link points at box \(Text(fingerprint).font(Theme.number(16))). Connecting it replaces \(known.label) as the home this app shows and controls. Your key for \(known.label) stays on this phone.")
            } else {
                Text("This link points at box \(Text(fingerprint).font(Theme.number(16))). Only continue if you just opened Settings → FTW app and chose Show pairing code in this box's local dashboard.")
            }
        }
        if let message = model.message { Problem(message) }
        Button(known != nil ? "Connect \(fingerprint)" : "Connect this box") {
            Task { await model.acceptOffer() }
        }
        .buttonStyle(.primary)
        Button("Not now") { model.declineOffer() }.buttonStyle(.quiet)
    }

    @ViewBuilder private var intro: some View {
        Title(problem != nil ? "Get this phone back in" : model.canOpen ? "Welcome back" : "Connect FTW")
        if let problem {
            Text(problem)
        } else if model.canOpen {
            Text("Your key is still on this phone. Nothing to set up again.")
        } else {
            Text(app.canDemo ? "Connect your own box, or try a live simulated home first." : "Connect your own box.")
        }
        if let message = model.message { Problem(message) }

        if problem == nil, !canDismiss, !model.canOpen, app.canDemo {
            demoOffer
        }

        if model.canOpen, let known = model.known {
            Button("Open \(known.label)") { model.openKnown() }.buttonStyle(.primary)
            Button("Scan a new pairing QR") { model.stage = .scanning }.buttonStyle(.quiet)
            Hint("Use a new QR from Settings → FTW app if this key no longer works.")
        } else {
            setup
        }

        if canDismiss {
            Button("Not now") { model.dismiss() }.buttonStyle(.quiet)
        }
    }

    private var demoOffer: some View {
        Card {
            Kicker("Interactive demo")
            Text("See a home running").font(.title3.weight(.semibold))
            Text("Explore live solar, battery, grid, prices and EV charging. The data is simulated and nothing is saved.")
                .foregroundStyle(Theme.fgDim)
            Button("Try the live demo") { model.tryDemo() }.buttonStyle(.primary)
        }
    }

    private var setup: some View {
        Card {
            Text("Connect your own box").font(.title3.weight(.semibold))
            Hint("The QR code is inside FTW Settings. It is not printed on the Raspberry Pi or its case.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open your box's local FTW dashboard while on your home network.")
                Text("2. Go to Settings → FTW app.")
                Text("3. Choose Show pairing code, then scan the QR here.")
            }
            .font(.callout)
            Hint("Next, your phone asks for Face ID or Touch ID to protect your FTW key. There is no FTW account or password. If this phone loses its key, a new Settings QR is the way back.")
            Button("Scan the pairing QR") { model.stage = .scanning }.buttonStyle(.primary)
            #if targetEnvironment(simulator)
            // The simulator has no camera. A screenshot of the QR in Photos
            // takes the same path as a scan.
            PhotosPicker("Choose a picture of the QR", selection: $picture, matching: .images)
                .buttonStyle(.quiet)
                .onChange(of: picture) { _, item in read(item) }
            #endif
            DisclosureGroup("Can't see Show pairing code?") {
                Hint("Turn on Let the FTW app connect to this box, save, and restart the box first.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
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
            .foregroundStyle(Theme.importing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
