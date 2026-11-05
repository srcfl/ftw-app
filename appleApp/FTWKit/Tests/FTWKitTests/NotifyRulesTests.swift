import Foundation
import Testing
@testable import FTWDemo
@testable import FTWKit
import FTWShared

/// Home › Notifications: the box's own rules, written as the web app writes
/// them (Fredrik, 5 Nov 2026: every notification choice in the iPhone app
/// too).
@Suite struct NotifyRulesTests {
    @Test func aWriteSendsWholeEntriesForKindsThePhoneKnows() {
        let events: [JSON] = [
            ["type": "driver_offline", "enabled": false, "threshold_s": 600],
            ["type": "fuse.over_limit", "enabled": false, "threshold_s": 30, "cooldown_s": 900],
            ["type": "some.future_kind", "enabled": true],
        ]
        let body = NotifyRules.body(events: events, on: ["fuse.over_limit": true, "driver_offline": true], boxOn: true)
        #expect(body["enabled"]?.bool == true)
        let sent = body["events"]?.array ?? []
        // The template rule and the kind this phone cannot name stay as the
        // box holds them; the one it knows goes out whole.
        #expect(sent.count == 1)
        #expect(sent.first?["type"]?.string == "fuse.over_limit")
        #expect(sent.first?["enabled"]?.bool == true)
        #expect(sent.first?["threshold_s"]?.number == 30)
        #expect(sent.first?["cooldown_s"]?.number == 900)
    }

    @Test func everyChoiceHasAGroupALabelAndSwedish() {
        #expect(!NotifyRules.choices.contains(PushKind.boxUnreachable))
        #expect(NotifyRules.choices.contains(PushKind.controlNotFollowing))
        for kind in NotifyRules.choices {
            guard let en = NotifyRules.labels[kind] else {
                Issue.record("\(kind) has no label")
                continue
            }
            #expect(NodeWords.sv[en] != nil, "no Swedish for \"\(en)\"")
        }
        #expect(NotifyRules.group(PushKind.carWhich) == .car)
        #expect(NotifyRules.group(PushKind.chargingGoalAtRisk) == .car)
        #expect(NotifyRules.group(PushKind.controlNotFollowing) == .home)
        #expect(NotifyRules.group(PushKind.ownerAdded) == .access)
        AppWords.$language.withValue(.sv) {
            #expect(NotifyRules.label(PushKind.controlNotFollowing) == "Om en enhet inte gör som FTW ber")
        }
    }

    @MainActor
    @Test func theSwitchesReadAndWriteTheBoxsRules() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        await rig.run(1_500)
        // The demo's clock moves only as the rig drives it, so each call
        // runs beside the rig.
        func drive(_ work: @escaping @MainActor () async -> Void) async {
            let task = Task { @MainActor in await work() }
            await rig.run(2_000)
            await task.value
        }
        await drive { await home.notify.load() }
        #expect(home.notify.phase == .ready)
        #expect(home.notify.kinds == NotifyRules.choices)
        #expect(home.notify.boxOn == false)
        #expect(home.notify.on[PushKind.controlNotFollowing] == true)
        #expect(home.notify.on[PushKind.chargingConnected] == false)

        // A kind turned on turns the box's own switch on too.
        await drive { await home.notify.set(PushKind.chargingConnected, true) }
        #expect(box.notifyOn)
        #expect(home.notify.boxOn)
        #expect(home.notify.on[PushKind.chargingConnected] == true)
        let rule = { (type: String) in box.notifyRules.first { $0["type"]?.string == type } }
        #expect(rule(PushKind.chargingConnected)?["enabled"]?.bool == true)
        #expect(rule(PushKind.chargingConnected)?["cooldown_s"]?.number == 60)
        #expect(rule(PushKind.fuseOverLimit)?["threshold_s"]?.number == 30)
        #expect(rule("driver_offline")?["threshold_s"]?.number == 600)

        // And off again for the whole home.
        await drive { await home.notify.setBoxOn(false) }
        #expect(!box.notifyOn)
        #expect(!home.notify.boxOn)
        #expect(rule(PushKind.chargingConnected)?["enabled"]?.bool == true)
    }
}
