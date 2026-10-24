import Foundation
import Testing
@testable import FTWDemo
@testable import FTWKit
import FTWShared

/// The status line under Now's title: whether this is now, and who controls
/// the home, in a few mono words that never count seconds.
@Suite struct StatusLineTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 10:00 UTC.
    static let t = CarTextTests.t

    func line(_ reach: StatusLine.Reach, _ control: StatusLine.Control = .ftw, receipt: StatusLine.Receipt? = nil, asOf: Double? = nil) -> StatusLine {
        StatusLine.make(.init(reach: reach, control: control, receipt: receipt, asOfMs: asOf, zone: Self.utc))
    }

    @Test func liveIsALitDotAndWhoControlsTheHome() {
        AppWords.$language.withValue(.en) {
            let live = line(.live)
            #expect(live.dot == .lit)
            #expect(live.text == "LIVE · FTW IN CONTROL")
            #expect(live.opens == .control)
            #expect(line(.live, .you).text == "LIVE · YOU'RE IN CONTROL")
            #expect(line(.demo).text == "DEMO · SIMULATED HOME")
            #expect(line(.demo).dot == .lit)
        }
    }

    /// Anything not live is a hollow ring and the clock time of the oldest
    /// reading on screen. It holds still while the clock moves.
    @Test func notLiveIsAHollowRingAndAClockTime() {
        AppWords.$language.withValue(.en) {
            let cached = line(.connecting, asOf: Self.t + 5 * 60_000 + 40_000)
            #expect(cached.dot == .hollow)
            #expect(cached.text == "AS OF 10:05 · FTW IN CONTROL")
            #expect(line(.settled, asOf: Self.t).text == "AS OF 10:00 · FTW IN CONTROL")
            // Nothing on screen yet: connecting says only that.
            #expect(line(.connecting, asOf: nil).text == "CONNECTING…")
            #expect(line(.settled, asOf: nil).text == "CONNECTING…")
        }
    }

    @Test func outOfReachSaysSoAndOpensHelp() {
        AppWords.$language.withValue(.en) {
            let lost = line(.cantReach, asOf: Self.t)
            #expect(lost.text == "AS OF 10:00 · CAN'T REACH THE BOX ›")
            #expect(lost.opens == .help)
            #expect(line(.cantReach).text == "CAN'T REACH THE BOX ›")
            #expect(line(.offline, asOf: Self.t).text == "AS OF 10:00 · PHONE OFFLINE")
            #expect(line(.busy, asOf: Self.t).text == "AS OF 10:00 · FTW BUSY")
            #expect(line(.starting(45)).text == "BOX STARTING · 45\u{00A0}%")
            #expect(line(.ended, receipt: .sent).text == "ACCESS ENDED")
        }
    }

    /// Dispatch blocked and devices gone quiet are said in alarm red; the
    /// rest of the line stays ink.
    @Test func aBlockOrAQuietDeviceIsAnAlarm() {
        AppWords.$language.withValue(.en) {
            let paused = line(.live, .paused)
            #expect(paused.text == "LIVE · ▲ PAUSED · METER STALE")
            #expect(paused.parts.map(\.tone) == [.ink, .alarm, .alarm])
            #expect(paused.dot == .lit)
            #expect(line(.live, .quiet(1)).text == "LIVE · ▲ 1 DEVICE QUIET")
            #expect(line(.settled, .quiet(2), asOf: Self.t).text == "AS OF 10:00 · ▲ 2 DEVICES QUIET")
        }
    }

    /// A mode change takes the second half of the line until the box has
    /// answered; confirmed is lime, refused is alarm red.
    @Test func aModeChangeShowsTheBoxsReceipt() {
        AppWords.$language.withValue(.en) {
            #expect(line(.live, receipt: .waiting).text == "LIVE · SENDING…")
            #expect(line(.live, receipt: .sent).text == "LIVE · SENT ▸")
            #expect(line(.live, receipt: .accepted).text == "LIVE · SENT ▸ ACCEPTED ▸")
            let done = line(.live, receipt: .confirmed)
            #expect(done.text == "LIVE · SENT ▸ CONFIRMED")
            #expect(done.parts.last?.tone == .live)
            #expect(line(.live, receipt: .refused).parts.last == .init(text: "▲ REFUSED", tone: .alarm))
            #expect(line(.demo, receipt: .unconfirmed).text == "DEMO · ▲ NOT CONFIRMED")
        }
    }

    /// The parts that stay through a receipt are the same parts, so a
    /// screen keeps them in place and fades in only the new step. The
    /// receipt's words are the receipt log's, the car's too.
    @Test func aReceiptKeepsItsPartsAndTheReceiptLogsWords() {
        AppWords.$language.withValue(.en) {
            let steps: [StatusLine.Receipt] = [.sent, .accepted, .confirmed]
            let lines = steps.map { line(.demo, receipt: $0) }
            #expect(lines.map(\.text) == ["DEMO · SENT ▸", "DEMO · SENT ▸ ACCEPTED ▸", "DEMO · SENT ▸ CONFIRMED"])
            // DEMO and SENT ▸ hold from step to step, word and colour.
            for l in lines { #expect(Array(l.parts.prefix(2)) == Array(lines[0].parts.prefix(2))) }
            #expect(lines.allSatisfy { $0.dot == .lit })
            let sent = lines[0].parts[1]
            #expect(sent.text == "\(ReceiptLog.word(.sent)) ▸")
            #expect(lines[1].parts[2].text == "\(ReceiptLog.word(.accepted)) ▸")
            #expect(lines[2].parts[2] == .init(text: ReceiptLog.word(.confirmed), tone: .live, joiner: " "))
            #expect(line(.live, receipt: .refused).parts.last?.text == "▲ \(ReceiptLog.refusedWord)")
            // The line without the receipt keeps DEMO too.
            #expect(line(.demo).parts.first == lines[0].parts.first)
        }
    }

    /// The demo's stream gone quiet: a hollow ring and the clock time, as
    /// a real home says it, never a lit dot.
    @Test func aQuietDemoSaysAsOfWithAHollowRing() {
        AppWords.$language.withValue(.en) {
            let quiet = line(.demoQuiet, asOf: Self.t + 5 * 60_000)
            #expect(quiet.dot == .hollow)
            #expect(quiet.text == "DEMO · AS OF 10:05")
            #expect(line(.demoQuiet, receipt: .sent, asOf: Self.t).text == "DEMO · AS OF 10:00 · SENT ▸")
        }
    }

    @Test func inSwedish() {
        AppWords.$language.withValue(.sv) {
            #expect(line(.live).text == "LIVE · FTW STYR")
            #expect(line(.settled, asOf: Self.t).text == "PER 10:00 · FTW STYR")
            #expect(line(.live, .paused).text == "LIVE · ▲ PAUSAD · MÄTAREN TYST")
            // The receipt in the receipt log's words, which follow the
            // phone's language: SKICKAT ▸ BEKRÄFTAT on a Swedish phone.
            #expect(line(.live, receipt: .confirmed).text == "LIVE · \(ReceiptLog.word(.sent)) ▸ \(ReceiptLog.word(.confirmed))")
            #expect(line(.demoQuiet, asOf: Self.t).text == "DEMO · PER 10:00")
            #expect(line(.cantReach).text == "NÅR INTE BOXEN ›")
            #expect(line(.demo).text == "DEMO · SIMULERAT HEM")
        }
    }

    /// Fredrik's rule: no ticking seconds. No state, in either language,
    /// writes an age in seconds or minutes, and a clock time moves only by
    /// the minute.
    @Test func theLineNeverCountsSeconds() {
        let reaches: [StatusLine.Reach] = [.live, .settled, .connecting, .cantReach, .offline, .busy, .starting(12), .starting(nil), .ended, .demo, .demoQuiet]
        let controls: [StatusLine.Control] = [.ftw, .you, .paused, .quiet(1), .quiet(3), .unknown]
        let receipts: [StatusLine.Receipt?] = [nil, .waiting, .sent, .accepted, .confirmed, .unconfirmed, .refused]
        for language in [AppWords.Language.en, .sv] {
            AppWords.$language.withValue(language) {
                var seen = Set<String>()
                for r in reaches {
                    for c in controls {
                        for p in receipts {
                            for second in stride(from: 0.0, to: 60_000, by: 7_000) {
                                let text = line(r, c, receipt: p, asOf: Self.t + second).text
                                seen.insert(text)
                                #expect(text.range(of: #"\d+\s?(s|sek|min)\b"#, options: .regularExpression) == nil, "\(text)")
                                #expect(!text.lowercased().contains("ago"), "\(text)")
                                #expect(!text.contains("sedan"), "\(text)")
                            }
                        }
                    }
                }
                // Within one minute, the seconds never change the words.
                #expect(line(.settled, asOf: Self.t).text == line(.settled, asOf: Self.t + 59_000).text)
                #expect(seen.count >= 40)
            }
        }
    }
}

/// The line against a home: the simulated box over the loopback, a mode
/// change from tap to answer, and the line coming back afterwards.
@MainActor
@Suite struct StatusLineSiteTests {
    @Test func aLiveHomeSaysLiveAndFTWInControl() async throws {
        let rig = DemoRig()
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: rig.scheduler, files: nil, shared: nil)
        site.start()
        let mode = ModeModel(site: site)
        AppWords.$language.withValue(.en) {
            let before = StatusLine.make(StatusLine.facts(site: site, mode: mode, demo: false, online: true, noCarrier: false, receipt: nil))
            #expect(before.text == "CONNECTING…")
            #expect(before.dot == .hollow)
        }
        site.connect(SimulatedBox.loopback(rig.scheduler))
        await rig.run(3_000)
        AppWords.$language.withValue(.en) {
            let live = StatusLine.make(StatusLine.facts(site: site, mode: mode, demo: false, online: true, noCarrier: false, receipt: nil))
            #expect(live.text == "LIVE · FTW IN CONTROL")
            #expect(live.dot == .lit)
            // Readings arriving now outrank an old sentence of help.
            let stillLive = StatusLine.make(StatusLine.facts(site: site, mode: mode, demo: false, online: true, noCarrier: true, receipt: nil))
            #expect(stillLive.text == "LIVE · FTW IN CONTROL")
        }
    }

    @Test func aModeChangeHoldsTheLineUntilTheBoxAnswersThenLetsGo() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let mode = home.nodes.mode
        await rig.run(3_000)
        func now() -> StatusLine {
            AppWords.$language.withValue(.en) {
                StatusLine.make(StatusLine.facts(site: home.site, mode: mode, demo: true, online: true, noCarrier: false, receipt: StatusLine.receipt(mode, nowMs: home.site.scheduler.nowMs)))
            }
        }
        #expect(now().text == "DEMO · SIMULATED HOME")
        // The clock moves only when the test moves it, so the command runs
        // beside it; the box answers 0.9 s after the tap.
        let task = Task { await mode.set("idle") }
        await rig.run(100)
        #expect(["DEMO · SENT ▸", "DEMO · SENT ▸ ACCEPTED ▸"].contains(now().text))
        await rig.run(1_500)
        await task.value
        #expect(now().text == "DEMO · SENT ▸ CONFIRMED")
        await rig.run(StatusLine.receiptShownMs)
        #expect(now().text == "DEMO · SIMULATED HOME")
    }

    /// The demo's stream goes quiet: the dot goes out and the line says
    /// when, as a real home's does; it lights again when the stream is back.
    @Test func aQuietDemoGoesHollow() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        await rig.run(3_000)
        func now() -> StatusLine {
            AppWords.$language.withValue(.en) {
                StatusLine.make(StatusLine.facts(site: home.site, mode: home.nodes.mode, demo: true, online: true, noCarrier: false, receipt: nil))
            }
        }
        #expect(now().text == "DEMO · SIMULATED HOME")
        #expect(now().dot == .lit)
        box.mute = true
        await rig.run(5_000)
        #expect(now().dot == .hollow)
        #expect(["DEMO · AS OF 11:59", "DEMO · AS OF 12:00"].contains(now().text))
        box.mute = false
        await rig.run(3_000)
        #expect(now().text == "DEMO · SIMULATED HOME")
    }

    /// The stream goes quiet: the dot goes out, and the line says the clock
    /// time of the last reading and holds it while the clock runs.
    @Test func aQuietStreamSaysAsOfAndHoldsStill() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        await rig.run(3_000)
        func now() -> StatusLine {
            AppWords.$language.withValue(.en) {
                StatusLine.make(StatusLine.facts(site: home.site, mode: home.nodes.mode, demo: false, online: true, noCarrier: false, receipt: nil))
            }
        }
        #expect(now().text == "LIVE · FTW IN CONTROL")
        box.mute = true
        await rig.run(5_000)
        let quiet = now()
        #expect(quiet.dot == .hollow)
        // The oldest reading on screen: the box read its devices a moment
        // before the last frame, which left at 12:00:03.
        #expect(["AS OF 11:59 · FTW IN CONTROL", "AS OF 12:00 · FTW IN CONTROL"].contains(quiet.text))
        await rig.run(20_000)
        #expect(now() == quiet)
        box.mute = false
        await rig.run(3_000)
        #expect(now().text == "LIVE · FTW IN CONTROL")
    }

    /// A manual mode is the household's own choice: the line says so.
    @Test func aManualModeSaysYoureInControl() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        await rig.run(3_000)
        #expect(StatusLine.control(site: home.site, mode: home.nodes.mode) == .ftw)
        let task = Task { await home.nodes.mode.set("idle") }
        await rig.run(2_000)
        await task.value
        #expect(StatusLine.control(site: home.site, mode: home.nodes.mode) == .you)
    }
}

/// The home's name as Now's title.
@Suite struct HomeNameTests {
    @Test func aHomeWithoutANameIsHomeInThePhonesLanguage() {
        AppWords.$language.withValue(.en) {
            #expect(HomeName.title(nil) == "Home")
            #expect(HomeName.title("Home") == "Home")
            #expect(HomeName.title("Stugan") == "Stugan")
            #expect(HomeName.demo == "Demo home")
        }
        AppWords.$language.withValue(.sv) {
            #expect(HomeName.title("Home") == "Hem")
            #expect(HomeName.demo == "Demohem")
        }
    }
}

/// Now's fixed page: the flow's size and place come from the screen and the
/// home's shape alone.
@Suite struct NowLayoutTests {
    /// 72 % of the room, from 232 pt to 420 pt, centred: the ground above
    /// the flow and the ground below it match.
    @Test func theFlowTakesItsShareOfTheRoomCentred() {
        // A small room: the floor, centred.
        let small = NowLayout(room: 300)
        #expect(small.flow == 232)
        // An SE: 72 % of the room.
        let se = NowLayout(room: 444)
        #expect(abs(se.flow - 444 * 0.72) < 0.001)
        // A Pro: 72 % of the room.
        let pro = NowLayout(room: 520)
        #expect(abs(pro.flow - 520 * 0.72) < 0.001)
        // A Pro Max reaches the cap: never more than 420 pt.
        let pm = NowLayout(room: 731)
        #expect(pm.flow == 420)
        #expect(NowLayout(room: 2_000).flow == 420)
        for l in [se, pm, NowLayout(room: 2_000), NowLayout(room: 300)] {
            let room = l.flow + l.grow + 2 * l.above
            let below = room - l.above - l.flow - l.grow
            #expect(abs(l.above - below) < 0.001, "\(l)")
        }
    }

    /// What the flow leaves, the price row takes 15 % of, from 20 pt to
    /// 56 pt, and never the gap the flow keeps from the plan.
    @Test func thePriceRowGrowsWithTheGround() {
        let pm = NowLayout(room: 731)
        #expect(abs(pm.price - (731 - 420) * 0.15) < 0.001)
        #expect(NowLayout(room: 444).price == 20)
        #expect(NowLayout(room: 2_000).price == 56)
        #expect(NowLayout(room: 300).price == 20)
        #expect(NowLayout(room: 240).price == 20)
        #expect(NowLayout(room: 240).grow == 0)
    }

    /// A small room: the flow gives way before the gap does, and nothing is
    /// ever below zero.
    @Test func aSmallRoomKeepsTheGap() {
        #expect(NowLayout(room: 200).flow == 200 - NowLayout.gap)
        #expect(NowLayout(room: 200).above == 0)
        #expect(NowLayout(room: 240).above == 0)
        #expect(NowLayout(room: -5).flow == 0)
        #expect(NowLayout(room: -5).above == 0)
        #expect(NowLayout(room: -5).price == 20)
    }

    /// A node on the axis asks for more, past the cap, within the room.
    @Test func aNodeOnTheAxisAsksForMore() {
        let y = FlowPlan.least([.solar, .battery, .home, .grid])
        #expect(y > NowLayout.minFlow)
        // Where 72 % of the room is less than the axis needs.
        #expect(NowLayout(room: 400, least: y).flow == y)
        #expect(NowLayout(room: 2_000, least: y).flow == max(y, 420))
        #expect(NowLayout(room: 250, least: y).flow == 250 - NowLayout.gap)
        #expect(FlowPlan.least([.solar, .battery, .home, .grid, .car]) == NowLayout.minFlow)
    }
}
