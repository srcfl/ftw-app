import FTWKit
import SwiftUI

/// The Apple Watch row in Settings: an owner lets the watch work without
/// this phone, with one passkey step-up (srcfl/ftw ADR 0009). Shown only
/// when a watch with FTW offered its key and the box can take it.
struct WatchSettingsSection: View {
    let app: AppModel
    let home: HomeModels

    var body: some View {
        let watch = app.watch
        Section {
            if watch.isAdded(home) {
                Label(AppWords.text("Works without your iPhone"), systemImage: "applewatch.radiowaves.left.and.right")
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("settings.watch.added")
            } else {
                Button {
                    Task { await watch.add(home) }
                } label: {
                    LabeledContent {
                        if watch.adding { ProgressView() }
                    } label: {
                        Label(AppWords.text("Let the watch work without your iPhone"), systemImage: "applewatch")
                    }
                }
                .disabled(watch.adding)
                .accessibilityIdentifier("settings.watch.add")
            }
        } header: {
            Text(AppWords.text("Apple Watch"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let failure = watch.failure {
                    Text(failure).foregroundStyle(Theme.alarm)
                }
                Text(AppWords.text(watch.isAdded(home)
                    ? "The watch charges the car and reads your home through FTW Cloud when this iPhone is away. Your box checks every command."
                    : "Confirm with your passkey. The watch can then charge the car from anywhere, never more than this phone may."))
            }
        }
    }
}
