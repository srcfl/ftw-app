import AppIntents
import FTWKit
import FTWShared
import SwiftUI

/// "Is the car ready?" Reading is not a privilege, so a locked phone
/// answers too, but with the gist alone: no level, no time, no power. The
/// card under the answer offers the one command that fits, and that button
/// asks for the unlocked phone like every other command.
struct CarStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is the car ready?"
    static let description = IntentDescription("Says whether the car will be ready in time, from what your box says now. A locked iPhone gives the gist only.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        guard let runner = IntentRunner.shared, let answer = await runner.answer() else {
            throw IntentFailure(ChargeNowActivity.openAndRetry)
        }
        let nowMs = Date.now.timeIntervalSince1970 * 1000
        return .result(dialog: IntentDialog(stringLiteral: answer.spoken(nowMs: nowMs)), snippetIntent: CarCardIntent(said: answer.headline))
    }
}

/// The card under the answer. The system runs it again after a button on
/// it, so it shows the box's newest account. The answer Siri gave sits
/// above the card; the card repeats it only once it has changed.
struct CarCardIntent: SnippetIntent {
    static let title: LocalizedStringResource = "The car"
    static let isDiscoverable = false

    @Parameter(title: "Said")
    var said: String?

    init() {}

    init(said: String) {
        self.said = said
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: CarCard(answer: IntentRunner.shared?.currentAnswer(), said: said, nowMs: Date.now.timeIntervalSince1970 * 1000))
    }
}

struct CarCard: View {
    let answer: CarAnswer?
    let said: String?
    let nowMs: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer {
                if answer.headline != said {
                    Label {
                        Text(answer.headline).font(.headline)
                    } icon: {
                        Image(systemName: Self.symbol(answer.gist)).foregroundStyle(.tint)
                    }
                }
                if !answer.details.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(answer.details, id: \.self) { Text($0) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
                }
                if let read = answer.readText(nowMs: nowMs) {
                    Text(read).font(.caption).foregroundStyle(.secondary)
                }
                if answer.holding {
                    Button(intent: BackToPlanIntent(loadpointID: answer.loadpointID)) {
                        Label(ChargeNowActivity.backToPlan, systemImage: "calendar")
                    }
                    .buttonStyle(.borderedProminent)
                } else if answer.canChargeNow {
                    Button(intent: ChargeNowIntent()) {
                        Label(ChargeNowActivity.title, systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(ChargeNowActivity.openAndRetry).font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    static func symbol(_ gist: CarAnswer.Gist) -> String {
        switch gist {
        case .noCharger: return "ev.charger"
        case .unplugged: return "powerplug"
        case .chargingNow: return "bolt.car.fill"
        case .paused: return "pause.circle"
        case .ready: return "checkmark.circle.fill"
        case .onTrack: return "clock"
        case .short: return "exclamationmark.triangle"
        case .pluggedIn: return "car.fill"
        }
    }
}

/// What Siri, Spotlight and the Shortcuts app offer without setup. Fixed
/// phrases: no App Schema covers a car's charging, so Siri matches these
/// and not free speech.
struct FTWShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ChargeNowIntent(),
            phrases: [
                "Charge now with \(.applicationName)",
                "Start charging the car with \(.applicationName)",
            ],
            shortTitle: "Charge now",
            systemImageName: "bolt.car.fill"
        )
        AppShortcut(
            intent: CarStatusIntent(),
            phrases: [
                "Is the car ready in \(.applicationName)",
                "Ask \(.applicationName) if the car is ready",
            ],
            shortTitle: "Is the car ready?",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: SetLevelIntent(),
            phrases: [
                "Tell \(.applicationName) the car is at \(\.$level)",
                "Set the car's level in \(.applicationName)",
            ],
            shortTitle: "Car's level",
            systemImageName: "battery.75percent"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
