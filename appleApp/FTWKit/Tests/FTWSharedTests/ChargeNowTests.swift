import AppIntents
import Foundation
import Testing
@testable import FTWShared

/// Charge now outside the app: the Live Activity's state from the box's
/// answers, the rule that every command needs the phone unlocked, and what
/// each intent asks the app to send. In English, the development language.
@Suite struct ChargeNowTests {
    /// 2026-10-12 12:02:00 UTC, 14:02 in Stockholm.
    static let t: Double = 1_791_806_520_000
    static let stockholm = TimeZone(identifier: "Europe/Stockholm")!

    // MARK: The Live Activity

    /// Only the box's confirmation starts it; a read never does, because a
    /// read cannot say when Charge now began.
    @Test func onlyAConfirmationStartsIt() {
        let t = Self.t
        #expect(ChargeNowActivity.next(nil, .started(atMs: t)) == .start(.init(startedAtMs: t, confirmedAtMs: t)))
        #expect(ChargeNowActivity.next(nil, .seen(holding: true, atMs: t)) == .none)
        #expect(ChargeNowActivity.next(nil, .seen(holding: false, atMs: t)) == .none)
        #expect(ChargeNowActivity.next(nil, .stopped) == .none)
    }

    /// A read that finds it still on moves the confirmation and keeps the
    /// start; a second Charge now does the same.
    @Test func aReadKeepsTheStartAndMovesTheConfirmation() {
        let t = Self.t
        let on = ChargeNowActivity.State(startedAtMs: t, confirmedAtMs: t)
        #expect(ChargeNowActivity.next(on, .seen(holding: true, atMs: t + 600_000)) == .update(.init(startedAtMs: t, confirmedAtMs: t + 600_000)))
        #expect(ChargeNowActivity.next(on, .started(atMs: t + 60_000)) == .update(.init(startedAtMs: t, confirmedAtMs: t + 60_000)))
        // A read older than the confirmation does not move it back.
        #expect(ChargeNowActivity.next(.init(startedAtMs: t, confirmedAtMs: t + 60_000), .seen(holding: true, atMs: t)) == .update(.init(startedAtMs: t, confirmedAtMs: t + 60_000)))
    }

    /// Back to the plan, Pause, an unplug or a read without the hold end it.
    @Test func backToThePlanEndsIt() {
        let on = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t)
        #expect(ChargeNowActivity.next(on, .stopped) == .end)
        #expect(ChargeNowActivity.next(on, .seen(holding: false, atMs: Self.t + 1)) == .end)
    }

    /// The phone vouches for an hour after the box last confirmed it.
    @Test func itGoesStaleAnHourAfterTheLastConfirmation() {
        let s = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t + 600_000)
        #expect(s.staleDate.timeIntervalSince1970 * 1000 == Self.t + 600_000 + 3_600_000)
        #expect(s.startedAt.timeIntervalSince1970 * 1000 == Self.t)
    }

    /// Static words and the household's clock; no power, ever.
    @Test func theWordsSayWhenNotHowMuch() {
        let s = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t + 1_800_000)
        #expect(ChargeNowActivity.since(s, zone: Self.stockholm) == "Charging now since 14:02")
        #expect(ChargeNowActivity.sinceShort(s, zone: Self.stockholm) == "Since 14:02")
        #expect(ChargeNowActivity.confirmed(s, zone: Self.stockholm) == "Last confirmed 14:32 · open FTW")
        #expect(ChargeNowActivity.since(s, zone: TimeZone(identifier: "UTC")!) == "Charging now since 12:02")
        #expect(ChargeNowActivity.title == "Charge now")
        #expect(ChargeNowActivity.backToPlan == "Back to the plan")
        for word in ChargeNowWord.allCases {
            #expect(!word.rawValue.contains("kW"))
        }
    }

    @Test func everyChargeNowWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in ChargeNowWord.allCases {
            let sv = try #require(table[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(sv.components(separatedBy: "%@").count == word.rawValue.components(separatedBy: "%@").count)
            #expect(sv != word.rawValue)
        }
        #expect(table["Charging now since %@"] == "Laddar nu sedan %@")
        #expect(table["Back to the plan"] == "Tillbaka till planen")
    }

    // MARK: Unlock

    /// Every command from the lock screen, Siri, a Control or the Live
    /// Activity needs the phone unlocked, and runs in the background
    /// without opening the app.
    @Test func everyCommandNeedsTheUnlockedPhone() {
        #expect(ChargeNowIntent.authenticationPolicy == .requiresAuthentication)
        #expect(BackToPlanIntent.authenticationPolicy == .requiresAuthentication)
        #expect(SetLevelIntent.authenticationPolicy == .requiresAuthentication)
        #expect(ChargeNowIntent.supportedModes == .background)
        #expect(BackToPlanIntent.supportedModes == .background)
        #expect(SetLevelIntent.supportedModes == .background)
    }

    // MARK: What each intent sends

    @Test func eachIntentAsksForItsCommand() {
        #expect(ChargeNowIntent().command == .chargeNow)
        #expect(BackToPlanIntent(loadpointID: "garage").command == .backToPlan(loadpointID: "garage"))
        #expect(BackToPlanIntent().command == .backToPlan(loadpointID: nil))
        #expect(SetLevelIntent(level: .p40).command == .setLevel(pct: 40))
        #expect(CarLevel.allCases.map(\.rawValue) == Array(stride(from: 10, through: 100, by: 10)))
    }

    /// Without the app's runner nothing is sent, and the person is told to
    /// open FTW. With it, the box's sentence is the answer, and a refusal
    /// is an error the system shows.
    @Test func theAnswerComesFromTheApp() async throws {
        await #expect(throws: IntentFailure("Open FTW to charge now.")) {
            try await CommandHost.answer(.chargeNow, runner: nil)
        }
        await #expect(throws: IntentFailure("Open FTW, then try again.")) {
            try await CommandHost.answer(.backToPlan(loadpointID: nil), runner: nil)
        }
        let done = FakeRunner(RemoteOutcome(.done, "FTW started charging."))
        #expect(try await CommandHost.answer(.chargeNow, runner: done) == "FTW started charging.")
        #expect(await done.asked == [.chargeNow])
        let pending = FakeRunner(RemoteOutcome(.pending, "FTW received it."))
        #expect(try await CommandHost.answer(.setLevel(pct: 40), runner: pending) == "FTW received it.")
        let refused = FakeRunner(RemoteOutcome(.failed, "Plug the car in first."))
        await #expect(throws: IntentFailure("Plug the car in first.")) {
            try await CommandHost.answer(.setLevel(pct: 40), runner: refused)
        }
    }
}

private actor FakeRunner: CommandRunner {
    let outcome: RemoteOutcome
    var asked: [RemoteCommand] = []

    init(_ outcome: RemoteOutcome) {
        self.outcome = outcome
    }

    func run(_ command: RemoteCommand) async -> RemoteOutcome {
        asked.append(command)
        return outcome
    }
}
