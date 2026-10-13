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

    /// This phone's own command starts it, from the moment it is sent; a
    /// read never does, because a read cannot say when Charge now began.
    @Test func onlyThisPhonesCommandStartsIt() {
        let t = Self.t
        #expect(ChargeNowActivity.next(nil, .sent(atMs: t)) == .start(.init(phase: .sent, startedAtMs: t, confirmedAtMs: t)))
        #expect(ChargeNowActivity.next(nil, .started(atMs: t)) == .start(.init(startedAtMs: t, confirmedAtMs: t)))
        #expect(ChargeNowActivity.next(nil, .seen(holding: true, atMs: t)) == .none)
        #expect(ChargeNowActivity.next(nil, .seen(holding: false, atMs: t)) == .none)
        #expect(ChargeNowActivity.next(nil, .received(atMs: t)) == .none)
        #expect(ChargeNowActivity.next(nil, .refused) == .none)
        #expect(ChargeNowActivity.next(nil, .stopped) == .none)
    }

    /// Sent, received, on: each step only once it has happened, and on
    /// counts from the box's confirmation, not from the tap.
    @Test func theStepsFollowTheReceipt() {
        let t = Self.t
        let sent = ChargeNowActivity.State(phase: .sent, startedAtMs: t, confirmedAtMs: t)
        let received = ChargeNowActivity.State(phase: .received, startedAtMs: t, confirmedAtMs: t + 300)
        #expect(ChargeNowActivity.next(sent, .received(atMs: t + 300)) == .update(received))
        #expect(ChargeNowActivity.next(received, .started(atMs: t + 1_200)) == .update(.init(phase: .on, startedAtMs: t + 1_200, confirmedAtMs: t + 1_200)))
        // A read while it is on its way decides nothing; the answer does.
        #expect(ChargeNowActivity.next(received, .seen(holding: false, atMs: t + 500)) == .none)
        #expect(ChargeNowActivity.next(sent, .refused) == .end)
        #expect(ChargeNowActivity.next(received, .refused) == .end)
        // A second press while it is on leaves the card as it is.
        let on = ChargeNowActivity.State(startedAtMs: t, confirmedAtMs: t)
        #expect(ChargeNowActivity.next(on, .sent(atMs: t + 60_000)) == .none)
        #expect(ChargeNowActivity.next(on, .received(atMs: t + 60_000)) == .none)
        #expect(ChargeNowActivity.next(on, .refused) == .none)
    }

    /// A card from before the steps reads back as on.
    @Test func anOlderCardReadsBackAsOn() throws {
        let json = #"{"startedAtMs":1,"confirmedAtMs":2}"#
        let state = try JSONDecoder().decode(ChargeNowActivity.State.self, from: Data(json.utf8))
        #expect(state == .init(phase: .on, startedAtMs: 1, confirmedAtMs: 2))
        let round = try JSONDecoder().decode(ChargeNowActivity.State.self, from: JSONEncoder().encode(ChargeNowActivity.State(phase: .received, startedAtMs: 3, confirmedAtMs: 4)))
        #expect(round.phase == .received)
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

    /// The phone vouches for 15 minutes after the box last confirmed it;
    /// every read confirms it again.
    @Test func itGoesStaleFifteenMinutesAfterTheLastConfirmation() {
        let s = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t + 600_000)
        #expect(ChargeNowActivity.vouchMs == 15 * 60_000)
        #expect(s.staleDate.timeIntervalSince1970 * 1000 == Self.t + 600_000 + 900_000)
        #expect(!s.isStale(atMs: Self.t + 600_000 + 899_999))
        #expect(s.isStale(atMs: Self.t + 600_000 + 900_000))
        #expect(s.startedAt.timeIntervalSince1970 * 1000 == Self.t)
    }

    /// It names the state, not power, on the household's clock.
    @Test func theWordsNameTheStateNotThePower() {
        let s = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t + 1_800_000)
        #expect(ChargeNowActivity.since(s, zone: Self.stockholm) == "Charge now on since 14:02")
        #expect(ChargeNowActivity.confirmed(s, zone: Self.stockholm) == "Last confirmed 14:32 · open FTW")
        #expect(ChargeNowActivity.since(s, zone: TimeZone(identifier: "UTC")!) == "Charge now on since 12:02")
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
        #expect(table["Charge now on since %@"] == "Ladda nu på sedan %@")
        #expect(table["Back to the plan"] == "Tillbaka till planen")
    }

    /// Current, it says since when and counts. Stale, it never says "since"
    /// and never counts: it says when the box last confirmed it, stops the
    /// timer there and dims.
    @Test func aStaleCardNeverSaysSinceAndNeverCounts() {
        let s = ChargeNowActivity.State(startedAtMs: Self.t, confirmedAtMs: Self.t + 1_800_000)
        let live = ChargeNowActivity.face(s, stale: false, zone: Self.stockholm)
        #expect(live.headline == "Charge now on since 14:02")
        #expect(live.subtitle == "No time limit")
        #expect(live.timer == .running(from: s.startedAt))
        #expect(!live.dimmed)

        let stale = ChargeNowActivity.face(s, stale: true, zone: Self.stockholm)
        #expect(stale.headline == "Last confirmed 14:32 · open FTW")
        #expect(!stale.headline.contains("since"))
        #expect(stale.subtitle == "It may have changed since.")
        #expect(stale.timer == .stopped(from: s.startedAt, at: s.confirmedAt))
        #expect(stale.dimmed)
    }

    /// While the command is on its way the card says so, with no time yet,
    /// and gives up after a minute with no answer.
    @Test func theCardSaysWhatIsHappeningNow() {
        let t = Self.t
        let sent = ChargeNowActivity.State(phase: .sent, startedAtMs: t, confirmedAtMs: t)
        let a = ChargeNowActivity.face(sent, stale: false, zone: Self.stockholm)
        #expect(a.headline == "Sending Charge now…")
        #expect(a.subtitle == "Waiting for FTW")
        #expect(a.timer == .waiting)
        #expect(a.steps == 1)
        let b = ChargeNowActivity.face(.init(phase: .received, startedAtMs: t, confirmedAtMs: t), stale: false, zone: Self.stockholm)
        #expect(b.headline == "FTW received Charge now")
        #expect(b.subtitle == "Waiting for the charger")
        #expect(b.steps == 2)
        let c = ChargeNowActivity.face(.init(startedAtMs: t, confirmedAtMs: t), stale: false, zone: Self.stockholm)
        #expect(c.steps == 3)
        #expect(sent.staleDate.timeIntervalSince1970 * 1000 == t + ChargeNowActivity.answerMs)
        let lost = ChargeNowActivity.face(sent, stale: true, zone: Self.stockholm)
        #expect(lost.headline == "No answer from FTW · open FTW")
        #expect(lost.subtitle == "Charge now may not have started.")
        #expect(lost.timer == .waiting)
        #expect(lost.dimmed)
    }

    // MARK: The Control

    static func cars(_ cars: [CarEntry.Car], readAtMs: Double, src: SourceState = .live) -> CacheRead<CarEntry> {
        CacheRead(record: CacheRecord(siteId: "home", carrier: .relay, srcState: src, readAtMs: readAtMs, value: CarEntry(cars: cars)), origin: .app)
    }

    static func car(plugged: Bool, holding: Bool?, id: String = "garage") -> CarEntry.Car {
        CarEntry.Car(loadpointID: id, pluggedIn: plugged, socPct: 40, socSource: "inferred", socReadAtMs: nil, powerW: 0, targetSocPct: nil, holding: holding)
    }

    /// The tile shows what the box last confirmed, and nothing once that is
    /// too old to vouch for.
    @Test func theControlShowsOnlyWhatTheBoxConfirmed() {
        let t = Self.t
        func state(_ read: CacheRead<CarEntry>?, at: Double = t) -> ChargeNowControlState.Known {
            ChargeNowControlState.from(read, nowMs: at).known
        }
        #expect(state(Self.cars([Self.car(plugged: true, holding: true)], readAtMs: t)) == .on)
        #expect(state(Self.cars([Self.car(plugged: true, holding: false)], readAtMs: t)) == .off)
        // The car with a cable leads, wherever it sits.
        #expect(state(Self.cars([Self.car(plugged: false, holding: false, id: "a"), Self.car(plugged: true, holding: true, id: "b")], readAtMs: t)) == .on)
        #expect(ChargeNowControlState.from(Self.cars([Self.car(plugged: false, holding: false, id: "a"), Self.car(plugged: true, holding: true, id: "b")], readAtMs: t), nowMs: t).loadpointID == "b")
        #expect(state(Self.cars([Self.car(plugged: false, holding: false)], readAtMs: t)) == .noCar)
        #expect(state(Self.cars([], readAtMs: t)) == .noCar)
        // Old, from a box that was not answering, or from before the app
        // kept the hold: unknown, never on or off.
        #expect(state(Self.cars([Self.car(plugged: true, holding: true)], readAtMs: t), at: t + ChargeNowActivity.vouchMs + 1) == .unknown)
        #expect(state(Self.cars([Self.car(plugged: true, holding: true)], readAtMs: t, src: .stale)) == .unknown)
        #expect(state(Self.cars([Self.car(plugged: true, holding: nil)], readAtMs: t)) == .unknown)
        #expect(state(nil) == .unknown)

        #expect(ChargeNowControlState(known: .on).isOn)
        #expect(!ChargeNowControlState(known: .unknown).isOn)
        #expect(ChargeNowControlState(known: .on).label == "On")
        #expect(ChargeNowControlState(known: .noCar).label == "No car plugged in")
        #expect(ChargeNowControlState(known: .unknown).label == "Open FTW to check")
    }

    // MARK: Unlock

    /// Every command from the lock screen, Siri, a Control or the Live
    /// Activity needs the phone unlocked, and runs in the background
    /// without opening the app.
    @Test func everyCommandNeedsTheUnlockedPhone() {
        #expect(ChargeNowIntent.authenticationPolicy == .requiresAuthentication)
        #expect(BackToPlanIntent.authenticationPolicy == .requiresAuthentication)
        #expect(SetLevelIntent.authenticationPolicy == .requiresAuthentication)
        #expect(SetChargeNowIntent.authenticationPolicy == .requiresAuthentication)
        #expect(ChargeNowIntent.supportedModes == .background)
        #expect(BackToPlanIntent.supportedModes == .background)
        #expect(SetLevelIntent.supportedModes == .background)
        #expect(SetChargeNowIntent.supportedModes == .background)
        // Only the refusal opens the app, and only to say why.
        #expect(ShowRefusalIntent.supportedModes == .foreground(.immediate))
        // Siri can stop what it started.
        #expect(BackToPlanIntent.isDiscoverable)
    }

    // MARK: What each intent sends

    @Test func eachIntentAsksForItsCommand() {
        #expect(ChargeNowIntent().command == .chargeNow)
        #expect(BackToPlanIntent(loadpointID: "garage", home: "demo").command == .backToPlan(loadpointID: "garage", home: "demo"))
        #expect(BackToPlanIntent().command == .backToPlan(loadpointID: nil, home: nil))
        #expect(SetChargeNowIntent(value: true).command == .chargeNow)
        #expect(SetChargeNowIntent(value: false).command == .backToPlan(loadpointID: nil, home: nil))
        #expect(SetLevelIntent(level: .p40).command == .setLevel(pct: 40))
        // The car view's chips, and no more tiles than those.
        #expect(CarLevel.allCases.map(\.rawValue) == [20, 40, 60, 80])
    }

    /// Without the app's runner nothing is sent, and the person is told to
    /// open FTW. With it, the box's sentence is the answer, and a refusal
    /// is an error the system shows.
    @Test func theAnswerComesFromTheApp() async throws {
        await #expect(throws: IntentFailure("Open FTW to charge now.")) {
            try await CommandHost.answer(.chargeNow, runner: nil)
        }
        await #expect(throws: IntentFailure("Open FTW, then try again.")) {
            try await CommandHost.answer(.backToPlan(loadpointID: nil, home: nil), runner: nil)
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

    func show(refusal: String) async {}
}
