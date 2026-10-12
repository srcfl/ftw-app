import FTWKit
import SwiftUI

/// Removing this phone: what the app deletes here, and how the owner takes
/// the phone off the box, since no op lets a phone do that itself.
struct RemovePhoneView: View {
    let app: AppModel
    /// Closes Source & licenses, which has nothing left to show after.
    let close: () -> Void
    @State private var confirming = false

    var body: some View {
        List {
            Section {
                Text(AboutWords.text("This deletes what FTW keeps on this phone: the key to your home, the pairing, the saved readings and what the widgets show. Your box and everything on it stay as they are."))
                Text(AboutWords.text("FTW has no account with Sourceful. Your box keeps a row for this phone until you remove it there."))
                    .foregroundStyle(Theme.fgDim)
            }
            .font(.callout)

            if let id = app.vault.deviceIDOnBox {
                Section {
                    LabeledContent(AboutWords.text("Your box calls this phone")) {
                        Text(PhoneRemoval.nameOnBox(id))
                            .font(.body.monospaced())
                            .foregroundStyle(Theme.fg)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(PhoneRemoval.boxSteps(id).enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step)
                        } icon: {
                            Image(systemName: "\(index + 1).circle")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } header: {
                    Text(AboutWords.text("On your box"))
                } footer: {
                    Text(AboutWords.text("Once it is gone there, the box no longer lets this phone in. Do it before or after the step below."))
                }
            }

            Section {
                Button(AboutWords.text("Remove from this phone"), role: .destructive) { confirming = true }
                    // On the button, so the question points at what asked it.
                    .confirmationDialog(AboutWords.text("Remove this phone?"), isPresented: $confirming, titleVisibility: .visible) {
                        Button(AboutWords.text("Remove"), role: .destructive) {
                            close()
                            app.leave()
                        }
                        Button(AboutWords.text("Cancel"), role: .cancel) {}
                    } message: {
                        Text(AboutWords.text("FTW forgets your home on this phone. To come back, scan a new pairing QR from your box."))
                    }
            } header: {
                Text(AboutWords.text("On this phone"))
            } footer: {
                Text(AboutWords.text("If you made a passkey for FTW, it stays in the Passwords app, where you can delete it. Keep it if another device of yours still uses FTW."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(AboutWords.text("Remove this phone"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
