import Foundation
import Testing
@testable import FTWKit
@testable import FTWDemo
import FTWShared

/// What the energy tax refund screen says, from Core's
/// `GET /api/energy/battery-return` alone: whole kWh rounded down, the
/// hours behind the figure, the battery it was counted with, and the
/// box's reason in place of a figure when it has one.
@Suite struct BatteryReturnTests {
    static let zone = BatteryReturn.zone

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Double {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// 2 November 2026, 14:32 in Stockholm.
    static let now = at(2026, 11, 2, 14, 32)

    /// One year as Core's handler writes it.
    static func wire(year: Int = 2025, returned: Double = 1_234_999.6, hours: Int = 8_760, complete: Int = 8_721,
                     batteries: Int = 1, problem: String = "", months: [JSON]? = nil) -> JSON {
        let rows: [JSON] = months ?? (1...12).map { (m: Int) -> JSON in
            let returned: Double = m == 1 ? 96_400 : 95_000
            let complete: Double = m == 8 ? 699 : 730
            return ["month": .number(Double(m)), "returned_wh": .number(returned), "hours": 730, "complete_hours": .number(complete)]
        }
        return [
            "year": .number(Double(year)), "zone": "Europe/Stockholm", "returned_wh": .number(returned),
            "hours": .number(Double(hours)), "complete_hours": .number(Double(complete)),
            "efficiency": 0.8849, "capacity_wh": 13_500, "batteries": .number(Double(batteries)),
            "problem": .string(problem), "months": .array(rows),
        ]
    }

    static func glance(_ wire: JSON, year: Int = 2025, origin: StampOrigin = .relay, asOf: Double = now, language: AppWords.Language = .en) -> BatteryReturnGlance {
        AppWords.$language.withValue(language) {
            BatteryReturnGlance.make(year: year, answer: Stamped(BatteryReturn.report(wire)!, asOfMs: asOf, origin: origin), problem: nil, nowMs: now)
        }
    }

    // MARK: The wire

    @Test func itReadsCoresAnswer() throws {
        let r = try #require(BatteryReturn.report(Self.wire()))
        #expect(r.year == 2025)
        #expect(r.returnedWh == 1_234_999.6)
        #expect(r.hours == 8_760)
        #expect(r.completeHours == 8_721)
        #expect(r.efficiency == 0.8849)
        #expect(r.capacityWh == 13_500)
        #expect(r.batteries == 1)
        #expect(r.problem == "")
        #expect(r.months.count == 12)
        #expect(r.months[0] == BatteryReturn.Month(month: 1, returnedWh: 96_400, hours: 730, completeHours: 730))
        #expect(r.months[7].completeHours == 699)
    }

    /// The box's error, a body with no year, or nothing at all is not an
    /// answer, and a figure never comes out negative.
    @Test func whatIsNotAnAnswerIsNone() {
        #expect(BatteryReturn.report(["error": "year must be 2018 to 2026"]) == nil)
        #expect(BatteryReturn.report(nil) == nil)
        #expect(BatteryReturn.report(.array([])) == nil)
        let odd = BatteryReturn.report(["year": 2025, "returned_wh": -5, "months": [["month": 13, "hours": 1]]])
        #expect(odd?.returnedWh == 0)
        #expect(odd?.months.isEmpty == true)
        #expect(odd?.problem == "")
    }

    // MARK: Who and when

    /// Swedish law: a Swedish price area, whatever its case, and nothing
    /// else.
    @Test func itAppliesInSwedenAlone() {
        for zone in ["SE1", "SE2", "SE3", "SE4", "se3", " SE4"] { #expect(BatteryReturn.applies(zone: zone), "\(zone)") }
        for zone in [nil, "", "NO1", "DK1", "FI", "SE5", "SE"] as [String?] { #expect(!BatteryReturn.applies(zone: zone), "\(zone ?? "nil")") }
    }

    /// The running year and the three before it, on Swedish time, opening
    /// on the last one to end. Nothing before 2018.
    @Test func theYearsRunOnSwedishTime() {
        #expect(BatteryReturn.years(nowMs: Self.now) == [2026, 2025, 2024, 2023])
        #expect(BatteryReturn.defaultYear(nowMs: Self.now) == 2025)
        // 00:30 on New Year's Day in Stockholm is still the old year in UTC.
        let newYear = Self.at(2027, 1, 1, 0, 30)
        #expect(BatteryReturn.thisYear(nowMs: newYear) == 2027)
        #expect(BatteryReturn.defaultYear(nowMs: newYear) == 2026)
        let early = Self.at(2019, 6, 1)
        #expect(BatteryReturn.years(nowMs: early) == [2019, 2018])
        #expect(BatteryReturn.defaultYear(nowMs: Self.at(2018, 6, 1)) == 2018)
    }

    // MARK: What the screen says

    /// Whole kWh rounded down, as the box's page writes it, the hours
    /// behind it and the battery it was counted with.
    @Test func theFigureIsWholeKWhRoundedDown() {
        let g = Self.glance(Self.wire())
        #expect(!g.placeholder)
        #expect(g.figure == "1,234")
        #expect(g.unit == "kWh")
        #expect(g.word == "Grid electricity stored and sent back in 2025")
        #expect(g.lines == [
            "Complete readings for 8,721 of 8,760 hours.",
            "Counted with a 13.5\u{00A0}kWh battery that gives back at least 88\u{00A0}% of its charge.",
        ])
        #expect(g.footer == "AS OF 14:32")
        #expect(g.hasBasis)
        #expect(BatteryReturn.wholeKWh(999.99) == 0)
        #expect(BatteryReturn.wholeKWh(1_000) == 1)
        #expect(BatteryReturn.basisName(2025) == "ftw-battery-return-2025.csv")
    }

    @Test func eachMonthWithHoursIsARow() {
        var months = (1...12).map { (m: Int) -> JSON in
            let hours: Double = m <= 10 ? 744 : 0
            return ["month": .number(Double(m)), "returned_wh": 41_999, "hours": .number(hours), "complete_hours": .number(hours)]
        }
        months[2] = ["month": 3, "returned_wh": 0, "hours": 743, "complete_hours": 0]
        let g = Self.glance(Self.wire(year: 2026, months: months), year: 2026)
        #expect(g.months.map(\.month) == Array(1...10))
        #expect(g.months[0] == BatteryReturnGlance.Row(month: 1, name: "January", figure: "41\u{00A0}kWh", hours: "744 of 744 hours"))
        #expect(g.months[2].figure == "No readings")
        #expect(g.months[2].hours == "0 of 743 hours")
        // The running year says so.
        #expect(g.word == "Grid electricity stored and sent back in 2026 so far")
        #expect(g.lines[0].hasSuffix("The year is still running."))
    }

    /// A reason stands in place of a figure, and there is no basis to
    /// share.
    @Test func aProblemIsAReasonNotAFigure() {
        let size = Self.glance(Self.wire(returned: 0, problem: "battery_size"))
        #expect(size.figure == "—")
        #expect(size.word == "No figure for 2025")
        #expect(size.lines == ["Set the battery's size on your box's own page to get a figure. FTW needs to know how much it holds."])
        #expect(!size.hasBasis)
        #expect(size.months.isEmpty)
        #expect(Self.glance(Self.wire(batteries: 0, problem: "battery_size")).lines == ["FTW read no battery in 2025."])
        #expect(Self.glance(Self.wire(batteries: 2, problem: "batteries")).lines == [
            "FTW works this out for one battery with its size set. In 2025 it read 2 batteries, and a replaced battery counts as a second.",
        ])
        // A reason a later box adds still means no figure.
        #expect(Self.glance(Self.wire(problem: "something_new")).lines == ["Your box gives no figure for 2025."])
        let none = Self.glance(Self.wire(returned: 0, complete: 0))
        #expect(none.figure == "—")
        #expect(none.lines == ["FTW has no complete readings for 2025."])
        #expect(!none.hasBasis)
    }

    /// Before the box has said anything for the year, the shape waits;
    /// a failure says what happens now. An answer for another year is
    /// not this year's.
    @Test func beforeAnAnswerTheShapeWaits() {
        let waiting = AppWords.$language.withValue(.en) { BatteryReturnGlance.make(year: 2025, answer: nil, problem: nil, nowMs: Self.now) }
        #expect(waiting.placeholder)
        #expect(waiting.lines == ["Working out 2025…"])
        #expect(!waiting.hasBasis)
        let failed = AppWords.$language.withValue(.en) {
            BatteryReturnGlance.make(year: 2025, answer: nil, problem: "Your box didn't answer. Still trying.", nowMs: Self.now)
        }
        #expect(!failed.placeholder)
        #expect(failed.figure == "—")
        #expect(failed.lines == ["Your box didn't answer. Still trying."])
        let other = AppWords.$language.withValue(.en) {
            BatteryReturnGlance.make(year: 2024, answer: Stamped(BatteryReturn.report(Self.wire())!, asOfMs: Self.now, origin: .relay), problem: nil, nowMs: Self.now)
        }
        #expect(other.placeholder)
    }

    /// The phone's copy says so, and an answer from another day names it.
    @Test func theFooterDatesTheAnswer() {
        let kept = Self.glance(Self.wire(), origin: .cache, asOf: Self.at(2026, 10, 30, 9, 5))
        #expect(kept.footer == "SAVED ON THIS PHONE · AS OF 30 OCT 09:05")
    }

    @Test func inSwedish() {
        let g = Self.glance(Self.wire(), language: .sv)
        #expect(g.figure == "1\u{00A0}234")
        #expect(g.word == "Nätel som lagrats och skickats tillbaka 2025")
        #expect(g.lines == [
            "Fullständiga mätvärden för 8\u{00A0}721 av 8\u{00A0}760 timmar.",
            "Räknat med ett batteri på 13,5\u{00A0}kWh som ger tillbaka minst 88\u{00A0}% av sin laddning.",
        ])
        #expect(g.months[0].name == "Januari")
        #expect(g.months[0].hours == "730 av 730 timmar")
        #expect(g.footer == "PER 14:32")
    }

    /// Every word the screen and History's row hand to the refund's words
    /// has Swedish. Read from the source, so a new sentence without Swedish
    /// fails here.
    @Test func everyWordHasSwedish() throws {
        let source = try RepoFiles.read("appleApp/FTWKit/Sources/FTWKit/Format/BatteryReturn.swift")
            + RepoFiles.read("appleApp/FTW/UI/BatteryReturnView.swift")
            + RepoFiles.read("appleApp/FTW/UI/HistoryTab.swift")
        let call = #/(?:BatteryReturnWords|words)\.(?:text|format)\("((?:[^"\\]|\\.)*)"/#
        var english = Set(source.matches(of: call).map { String($0.1) })
        // Picked by a ternary inside a call: the call sees only the first.
        english.formUnion(["Grid electricity stored and sent back in %@", "Grid electricity stored and sent back in %@ so far"])
        #expect(english.count > 20)
        for en in english.sorted() {
            #expect(BatteryReturnWords.sv[en] != nil, "no Swedish for \"\(en)\"")
        }
    }
}

// MARK: The model

@MainActor
@Suite struct BatteryReturnModelTests {
    func refundAsks(_ w: ReturnRig, since from: Int = 0) -> [String] {
        w.asks(since: from).filter { $0.hasPrefix("GET /api/energy/battery-return") }
    }

    /// Nothing is asked until the screen opens. It asks for last year, once
    /// an hour while open, again for another year, and never on a timer
    /// while closed.
    @Test func itAsksForTheYearOnScreenByTheHour() async throws {
        let w = ReturnRig()
        w.dial()
        await w.run(3_000)
        #expect(refundAsks(w).isEmpty)
        let model = w.home.batteryReturn
        #expect(model.year == 2025)

        model.activate()
        await w.run(2_000)
        #expect(refundAsks(w) == ["GET /api/energy/battery-return"])
        let answer = try #require(model.answers[2025])
        #expect(answer.origin == .relay)
        #expect(answer.value.year == 2025)
        #expect(!model.glance.placeholder)

        // Another year is another question; going back to one already
        // answered this hour paints it at once.
        model.year = 2024
        await w.run(2_000)
        #expect(refundAsks(w).count == 2)
        #expect(model.answers[2024] != nil)
        model.year = 2025
        #expect(!model.glance.placeholder)
        await w.run(2_000)
        #expect(refundAsks(w).count == 3)

        // Closed and opened again within the hour asks nothing.
        model.deactivate()
        await w.run(60_000, step: 1_000)
        model.activate()
        await w.run(2_000)
        #expect(refundAsks(w).count == 3)

        // Two hours closed: no timer asked.
        model.deactivate()
        await w.run(2 * 3_600_000, step: 10_000)
        #expect(refundAsks(w).count == 3)

        // Opened in a later hour, it asks again.
        model.activate()
        await w.run(2_000)
        #expect(refundAsks(w).count == 4)
    }

    /// The demo's oldest year read two batteries: no figure, the reason.
    @Test func theDemoSaysWhyItsOldestYearHasNoFigure() async throws {
        let w = ReturnRig()
        w.dial()
        let model = w.home.batteryReturn
        model.year = 2023
        model.activate()
        await w.run(3_000)
        let g = AppWords.$language.withValue(.en) { model.glance }
        #expect(g.figure == "—")
        #expect(g.lines == ["FTW works this out for one battery with its size set. In 2023 it read 2 batteries, and a replaced battery counts as a second."])
        #expect(g.months.isEmpty)
    }

    /// The hourly basis comes from the box as the file the owner keeps,
    /// named as the box names its download, in Core's columns.
    @Test func theBasisIsTheBoxsCSV() async throws {
        let w = ReturnRig()
        w.dial()
        await w.run(3_000)
        let model = w.home.batteryReturn
        let file = Task { try await model.basis(2025) }
        await w.run(3_000)
        let url = try await file.value
        #expect(url.lastPathComponent == "ftw-battery-return-2025.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.first?.hasPrefix("hour_start,grid_import_wh,grid_export_wh,battery_charge_wh") == true)
        #expect(lines.count == 8_761)
        #expect(refundAsks(w) == ["GET /api/energy/battery-return.csv"])
    }

    /// A second launch opens on each year's last answer, marked as the
    /// phone's copy, before it has asked the box anything.
    @Test func itOpensOnTheLastAnswer() async throws {
        let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-refund-\(UUID().uuidString)"), store: MemoryStore())
        let first = ReturnRig(files: files)
        first.dial()
        first.home.batteryReturn.activate()
        await first.run(3_000)
        let said = try #require(first.home.batteryReturn.answers[2025])
        first.site.suspend()
        first.site.destroy()
        // The home's files are sealed off the main actor. Wait until this
        // one has landed, as a later launch would.
        for _ in 0..<500 where files.readJSON(BatteryReturnModel.File.self, "battery-return-home") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let second = ReturnRig(files: files, nowMs: first.scheduler.nowMs + 5 * 60_000)
        let kept = try #require(second.home.batteryReturn.answers[2025])
        #expect(kept.origin == .cache)
        #expect(kept.value == said.value)
        #expect(second.box.asks.isEmpty)
        let g = AppWords.$language.withValue(.en) { second.home.batteryReturn.glance }
        #expect(!g.placeholder)
        #expect(g.footer.hasPrefix("SAVED ON THIS PHONE · AS OF"))
    }
}
