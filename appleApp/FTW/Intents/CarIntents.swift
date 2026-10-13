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
    static let description = IntentDescription("Says whether the car will be ready in time, from what your box says now. A locked phone gives the gist only.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif

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
                // The answer Siri gave sits above the card; once a button
                // here changes the state, the new state fades in on top.
                if answer.headline != said {
                    Label {
                        Text(answer.headline)
                            .font(.headline)
                            .contentTransition(.interpolate)
                    } icon: {
                        Image(systemName: Self.symbol(answer.gist))
                            .foregroundStyle(.tint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !answer.details.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(answer.details, id: \.self) { Text($0).contentTransition(.interpolate) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
                }
                if let receipt = answer.receipt {
                    Text(receipt)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                        .contentTransition(.interpolate)
                        .transition(.opacity)
                }
                if let read = answer.readText(nowMs: nowMs) {
                    Text(read).font(.caption).foregroundStyle(.secondary)
                }
                // One button in one place: Charge now or Back to the plan,
                // its label and icon changing in place.
                if answer.holding || answer.canChargeNow {
                    Button(intent: CardCommandIntent(on: !answer.holding, loadpointID: answer.loadpointID, home: answer.home)) {
                        Label {
                            Text(answer.holding ? ChargeNowActivity.backToPlan : ChargeNowActivity.title)
                                .contentTransition(.interpolate)
                        } icon: {
                            Image(systemName: answer.holding ? "calendar" : "bolt.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(ChargeNowActivity.openAndRetry).font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .animation(Theme.spring, value: answer)
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

/// The card's one button. It answers with nothing of its own, so the card
/// stays where it is and redraws with the box's outcome instead of giving
/// way to a new answer.
struct CardCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Charge now"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let supportedModes: IntentModes = .background

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif

    @Parameter(title: "On")
    var on: Bool

    @Parameter(title: "Charger")
    var loadpointID: String?

    @Parameter(title: "Home")
    var home: String?

    init() {}

    init(on: Bool, loadpointID: String?, home: String) {
        self.on = on
        self.loadpointID = loadpointID
        self.home = home
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await IntentRunner.shared?.run(on ? .chargeNow : .backToPlan(loadpointID: loadpointID, home: home))
        return .result()
    }
}

/// It starts the Live Activity when it is Charge now, from wherever the
/// card is.
extension CardCommandIntent: LiveActivityIntent {}

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
            intent: BackToPlanIntent(),
            phrases: [
                "Back to the plan with \(.applicationName)",
                "Stop charging now with \(.applicationName)",
            ],
            shortTitle: "Back to the plan",
            systemImageName: "calendar"
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
