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

    /// No answer may still have run: a warning, not a failure. Something
    /// only the phone may send is not sent at all.
    @Test func noAnswerWarnsAndThePhonesOwnFail() {
        let none = WatchReceipt.box(c, .noAnswer)
        #expect(none.tone == .warning && none.sent == .waiting && none.settled)
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
