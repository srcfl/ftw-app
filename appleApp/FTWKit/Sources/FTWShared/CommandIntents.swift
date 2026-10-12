import AppIntents
import Foundation
import os
import Synchronization

// The commands a person can give FTW without opening the app: Charge now
// from a Control, the Action button or Siri; Back to the plan from the Live
// Activity; the car's level from Siri. They live here because the widget
// extension draws the Control and the Live Activity and so must know the
// types. Neither runs here: the app installs a runner at launch, and only
// the app holds the key that reaches the box.
//
// Every one of them needs the phone unlocked (Fredrik, 12 Oct 2026). A
// watch unlocked on the wrist counts; the system decides that, not FTW.

private let log = Logger(subsystem: "energy.ftw.app", category: "intents")

/// What a person asked for from outside the app.
public enum RemoteCommand: Sendable, Equatable {
    /// Charge now on the charger with a car, at its full current and with no
    /// time limit.
    case chargeNow
    /// Release Charge now or Pause. Nil means the charger that holds one.
    case backToPlan(loadpointID: String?)
    /// Tell FTW how full the car is, in whole percent.
    case setLevel(pct: Double)
}

/// How a command ended, in a sentence ready to show or speak.
public struct RemoteOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The box did it.
        case done
        /// The box has it and has not confirmed it yet. Not a failure.
        case pending
        /// It did not happen, and `text` says what to do.
        case failed
    }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Runs a command over the app's session with the box. Only the app has
/// one.
public protocol CommandRunner: Sendable {
    func run(_ command: RemoteCommand) async -> RemoteOutcome
}

/// Where an intent finds the runner. Empty in the widget extension.
public enum CommandHost {
    private static let installed = Mutex<(any CommandRunner)?>(nil)

    /// The app calls this once, at launch, before any intent can run.
    public static func install(_ runner: any CommandRunner) {
        installed.withLock { $0 = runner }
    }

    public static var runner: (any CommandRunner)? {
        installed.withLock { $0 }
    }

    /// Run `command` and turn its outcome into a dialog, or into an error
    /// the system shows. Without a runner this process is not the app; the
    /// person is told to open it, and nothing is sent.
    public static func answer(_ command: RemoteCommand, runner: (any CommandRunner)? = CommandHost.runner) async throws -> String {
        guard let runner else {
            log.fault("\(String(describing: command), privacy: .public) ran in \(Bundle.main.bundleIdentifier ?? "?", privacy: .public), which cannot reach the box")
            throw IntentFailure(command == .chargeNow ? ChargeNowWord.openToCharge.text : ChargeNowWord.openAndRetry.text)
        }
        let out = await runner.run(command)
        log.info("\(String(describing: command), privacy: .public): \(String(describing: out.kind), privacy: .public)")
        guard out.kind != .failed else { throw IntentFailure(out.text) }
        return out.text
    }
}

/// A command that did not happen, said as what to do now.
public struct IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}

// MARK: - The intents

/// Charge now: the charger's full current until Back to the plan or an
/// unplug. No time limit and no level gate, because the level is often a
/// guess (Fredrik, 4 Sep 2026).
///
/// A Live Activity intent, because it starts one, and because the system
/// then runs it in the app's process even when the Control lives in the
/// widget extension. `supportedModes` keeps it in the background; iOS 27
/// can say outright that it runs in the app.
public struct ChargeNowIntent: AppIntent {
    public static let title: LocalizedStringResource = "Charge now"
    public static let description = IntentDescription("Starts charging the car at once, until you go back to the plan.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public init() {}

    public var command: RemoteCommand { .chargeNow }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await CommandHost.answer(command)))
    }
}

/// Back to the plan: release Charge now or Pause, and let FTW decide again.
/// The Live Activity's button.
public struct BackToPlanIntent: AppIntent {
    public static let title: LocalizedStringResource = "Back to the plan"
    public static let description = IntentDescription("Ends Charge now or Pause. FTW decides when to charge again.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let supportedModes: IntentModes = .background
    /// The Live Activity names its charger; Siri and Shortcuts do not.
    public static let isDiscoverable = false

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Charger")
    public var loadpointID: String?

    public init() {}

    public init(loadpointID: String?) {
        self.loadpointID = loadpointID
    }

    public var command: RemoteCommand { .backToPlan(loadpointID: loadpointID) }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await CommandHost.answer(command)))
    }
}

/// The car's level, for a car FTW cannot read: `loadpoint.soc.set`. The box
/// takes it only while the car is plugged in, and says so otherwise.
public struct SetLevelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set the car's level"
    public static let description = IntentDescription("Tells FTW how full the car's battery is, when FTW cannot read it from the car.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Level")
    public var level: CarLevel

    public static var parameterSummary: some ParameterSummary {
        Summary("The car is at \(\.$level)")
    }

    public init() {}

    public init(level: CarLevel) {
        self.level = level
    }

    public var command: RemoteCommand { .setLevel(pct: Double(level.rawValue)) }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await CommandHost.answer(command)))
    }
}

/// The levels Siri understands. Ten steps: a level said aloud is a rough
/// one, and the car view has ±5 for the rest.
public enum CarLevel: Int, AppEnum, CaseIterable, Sendable {
    case p10 = 10, p20 = 20, p30 = 30, p40 = 40, p50 = 50, p60 = 60, p70 = 70, p80 = 80, p90 = 90, p100 = 100

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Level"
    public static let caseDisplayRepresentations: [CarLevel: DisplayRepresentation] = [
        .p10: "10 %", .p20: "20 %", .p30: "30 %", .p40: "40 %", .p50: "50 %",
        .p60: "60 %", .p70: "70 %", .p80: "80 %", .p90: "90 %", .p100: "100 %",
    ]
}

#if os(iOS)
extension ChargeNowIntent: LiveActivityIntent {}
extension BackToPlanIntent: LiveActivityIntent {}
#endif

/// The intents above, for the app and the widget extension to list in
/// their own `AppIntentsPackage`.
public struct FTWSharedIntents: AppIntentsPackage {}
