import Foundation
import Testing
@testable import FTWShared

/// The watch with two ways to its box: the phone, and FTW Cloud on its own.
/// The buttons hold still while the paths change places, and every mark of a
/// command through FTW Cloud is the box's own answer.
@Suite struct WatchReachTests {
    /// The first word says both answers; after that only a change speaks.
    @Test func eachAnswerIsSaidOnceAndOnlyWhenItChanges() {
        var reach = WatchReach()
        #expect(reach.set(phone: false, cloud: false) == [.canSend(false), .phoneReachable(false)])
        #expect(reach.set(phone: false, cloud: false).isEmpty)
        #expect(reach.set(cloud: true) == [.canSend(true)])
        #expect(reach.set(cloud: true).isEmpty)
    }

    /// The phone walks away from a watch FTW Cloud carries: commands can
    /// still leave, so the buttons do not blink. Only the phone's own word
    /// changes, which the mode alone needs.
    @Test func thePhoneWalkingAwayDoesNotBlinkTheButtons() {
        var reach = WatchReach()
        _ = reach.set(phone: true, cloud: true)
        #expect(reach.set(phone: false) == [.phoneReachable(false)])
        #expect(reach.set(phone: true) == [.phoneReachable(true)])
        #expect(reach.canSend)
    }

    /// Without FTW Cloud the phone's reach is the whole answer, as before.
    @Test func withoutTheCloudThePhoneDecides() {
        var reach = WatchReach()
        _ = reach.set(phone: true, cloud: false)
        #expect(reach.set(phone: false) == [.canSend(false), .phoneReachable(false)])
    }

    private let c = WatchCommand(op: .chargeNow(loadpointID: "garage"), home: "site", sentAtMs: 0)

    /// Sending, the box's ack, its confirmation: the marks fill in that
    /// order, and only the box's result confirms.
    @Test func aCommandThroughTheCloudShowsTheBoxsMarks() {
        let sending = WatchReceipt.box(c, .sending)
        #expect(sending.sent == .active && sending.accepted == .waiting && sending.confirmed == .waiting && !sending.settled)
        #expect(sending.text == "Sending to your box…")
        let pending = WatchReceipt.box(c, .pending)
        #expect(pending.accepted == .done && pending.confirmed == .active && !pending.settled)
        let applied = WatchReceipt.box(c, .applied)
        #expect(applied.confirmed == .done && applied.tone == .done && applied.text == "Charge now on")
        #expect(WatchReceipt.box(WatchCommand(op: .pause(loadpointID: "garage"), home: "site", sentAtMs: 0), .applied).text == "Charging paused")
        #expect(sending.taking(applied) == applied)
        // A settled end is not undone by a late step.
        #expect(applied.taking(pending) == nil)
    }

    /// A refusal says why in a wrist's words, and fails the last mark.
    @Test func aRefusalSaysWhy() {
        let mayNot = WatchReceipt.box(c, .refused(.mayNot))
        #expect(mayNot.confirmed == .failed && mayNot.tone == .failed && mayNot.text == "This watch may not do that. Use your iPhone.")
        #expect(WatchReceipt.box(c, .refused(.changed)).text == "Something changed on your box. Try again.")
        #expect(WatchReceipt.box(c, .refused(.tooLate)).text == WatchWord.tooLate.text)
        #expect(WatchReceipt.box(c, .refused(.other)).text == "Your box did not do that. Nothing changed.")
    }

    /// No answer once the command left may still have run: a warning, not
    /// a failure, and the box's ack stays. A box not reached and a watch
    /// FTW Cloud does not list sent nothing. Something only the phone may
    /// send is not sent at all.
    @Test func noAnswerWarnsAndThePhonesOwnFail() {
        let none = WatchReceipt.box(c, .noAnswer(acked: false))
        #expect(none.tone == .warning && none.sent == .done && none.accepted == .waiting && none.settled)
        let acked = WatchReceipt.box(c, .noAnswer(acked: true))
        #expect(acked.accepted == .done && acked.tone == .warning)
        let unread = WatchReceipt.box(c, .unread)
        #expect(unread.sent == .done && unread.accepted == .active && !unread.settled)
        let notReached = WatchReceipt.box(c, .notReached)
        #expect(notReached.sent == .failed && notReached.tone == .failed && notReached.text == "Your box can't be reached now. Nothing was sent.")
        let notListed = WatchReceipt.box(c, .notListed)
        #expect(notListed.sent == .failed && notListed.text == "Add this watch again from your iPhone. Nothing was sent.")
        let phone = WatchReceipt.box(c, .needsPhone)
        #expect(phone.tone == .failed && phone.sent == .failed)
    }

    /// One command by both paths: the box's confirmation through one is not
    /// undone by the other path saying it could not carry it.
    @Test func theBoxsConfirmationStandsAgainstTheOtherPath() {
        let applied = WatchReceipt.box(c, .applied)
        let phoneFailed = WatchReceipt(commandID: c.id, op: c.op, sent: .failed, accepted: .waiting, confirmed: .waiting, text: "Open FTW, then try again.", tone: .failed)
        #expect(applied.taking(phoneFailed) == nil)
        #expect(applied.taking(.unreachable(c)) == nil)
        #expect(WatchReceipt.box(c, .pending).taking(phoneFailed) == nil)
        // Before the box took it, the other path's word still counts.
        #expect(WatchReceipt.box(c, .sending).taking(phoneFailed) == phoneFailed)
    }
}

/// Which way each command goes, and when FTW Cloud is read.
@Suite struct WatchRouteTests {
    private let c = WatchCommand(op: .chargeNow(loadpointID: "garage"), home: "site", sentAtMs: 0)

    private func receipt(sent: WatchReceipt.Mark, accepted: WatchReceipt.Mark = .waiting, confirmed: WatchReceipt.Mark = .waiting,
                         tone: WatchReceipt.Tone = .working) -> WatchReceipt {
        WatchReceipt(commandID: c.id, op: c.op, sent: sent, accepted: accepted, confirmed: confirmed, text: "", tone: tone)
    }

    /// The phone failing a command FTW Cloud can carry hands it over under
    /// the same cmdId, and its failure does not reach the screen.
    @Test func thePhoneFailingHandsTheCommandToTheCloud() {
        var route = WatchRoute()
        #expect(route.send(c, phone: true, cloud: true, nowMs: 1_000) == .phone)
        let failed = receipt(sent: .failed, tone: .failed)
        let carry = route.phoneSaid(failed, cloud: true, nowMs: 2_000)
        #expect(carry == WatchRoute.Carry(command: c, leftMs: WatchCommand.lifeMs - 1_000))
        #expect(!route.shows(failed))
        // Handed over once.
        #expect(route.phoneSlow(c.id, cloud: true, nowMs: 4_000) == nil)
    }

    /// Any receipt short of the box's ack keeps the command the phone's
    /// only until `phoneTakesMs`, then FTW Cloud carries it too.
    @Test func aCommandStaysThePhonesOnlyOnceTheBoxAckedIt() {
        var route = WatchRoute()
        _ = route.send(c, phone: true, cloud: true, nowMs: 0)
        #expect(route.phoneSaid(receipt(sent: .done, accepted: .active), cloud: true, nowMs: 500) == nil)
        #expect(route.phoneSlow(c.id, cloud: true, nowMs: WatchRoute.phoneTakesMs)?.command == c)

        var acked = WatchRoute()
        _ = acked.send(c, phone: true, cloud: true, nowMs: 0)
        #expect(acked.phoneSaid(receipt(sent: .done, accepted: .done, confirmed: .active), cloud: true, nowMs: 500) == nil)
        #expect(acked.phoneSlow(c.id, cloud: true, nowMs: WatchRoute.phoneTakesMs) == nil)
    }

    /// Without FTW Cloud the phone's failure is the end, and is shown.
    @Test func withoutTheCloudThePhonesFailureStands() {
        var route = WatchRoute()
        _ = route.send(c, phone: true, cloud: false, nowMs: 0)
        let failed = receipt(sent: .failed, tone: .failed)
        #expect(route.phoneSaid(failed, cloud: false, nowMs: 100) == nil)
        #expect(route.shows(failed))
    }

    /// The phone out of reach: FTW Cloud carries the charger's commands,
    /// and the phone's late word that it could not is not shown. The mode
    /// goes nowhere.
    @Test func withoutThePhoneTheCloudCarriesTheChargersCommands() {
        var route = WatchRoute()
        #expect(route.send(c, phone: false, cloud: true, nowMs: 0) == .cloud(.init(command: c, leftMs: WatchCommand.lifeMs)))
        let late = route.phoneNotSent(c.id, cloud: true, nowMs: 100)
        #expect(late.carry == nil && !late.tell)
        let mode = WatchCommand(op: .mode("charge"), home: "site", sentAtMs: 0)
        #expect(route.send(mode, phone: false, cloud: true, nowMs: 0) == .nowhere)
        #expect(route.phoneNotSent(mode.id, cloud: true, nowMs: 100).tell)
    }

    /// The phone could not be reached for a command it was sent: FTW Cloud
    /// carries it, while it has life left.
    @Test func aCommandThePhoneNeverGotGoesByTheCloudWhileItLives() {
        var route = WatchRoute()
        _ = route.send(c, phone: true, cloud: true, nowMs: 0)
        let late = route.phoneNotSent(c.id, cloud: true, nowMs: 1_000)
        #expect(late.carry?.leftMs == WatchCommand.lifeMs - 1_000 && !late.tell)

        var old = WatchRoute()
        _ = old.send(c, phone: true, cloud: true, nowMs: 0)
        #expect(old.phoneSlow(c.id, cloud: true, nowMs: WatchCommand.lifeMs + 1) == nil)
    }

    /// FTW Cloud is read once per appearance: at once without the phone,
    /// after a wait with it, and not when the phone answered meanwhile.
    @Test func theCloudIsReadOncePerLookUnlessThePhoneAnswers() {
        var route = WatchRoute()
        #expect(route.look(phone: true, nowMs: 1_000) == WatchRoute.phoneWaitMs)
        #expect(route.look(phone: true, nowMs: 1_500) == nil)
        route.heardPhone(nowMs: 2_000)
        #expect(!route.readsCloud)
        route.away()
        #expect(route.look(phone: false, nowMs: 9_000) == 0)
        #expect(route.readsCloud)
        route.away()
        #expect(!route.readsCloud)
    }
}
