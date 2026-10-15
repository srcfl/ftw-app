import Foundation
import Testing
@testable import FTWKit
@testable import FTWDemo
import FTWShared

/// What the savings screen says, from the box's `GET /api/savings/daily`
/// rows and totals alone: the box's money, never the app's sums, never the
/// self-consumption baseline, a partial day as far as it got, and "partial"
/// when the box priced less than 95 % of the time.
@Suite struct SavingsGlanceTests {
    static let zone = TimeZone(identifier: "Europe/Stockholm")!

    /// 15 October 2026, 14:32 in Stockholm.
    static let now: Double = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 32))!.timeIntervalSince1970 * 1000
    }()

    /// One row as Core's ledger path writes it, self-consumption included.
    static func row(_ day: String, saved: Double, actual: Double = 3_370, coverage: Double = 1, resolution: String = "slot",
                    selfSaved: Double = -900) -> JSON {
        [
            "day": .string(day),
            "import_wh": 9_400, "export_wh": 3_100, "load_wh": 14_000, "pv_wh": 8_200, "ev_wh": 0,
            "import_cost_ore": .number(actual + 520), "export_revenue_ore": 520,
            "actual_cost_ore": .number(actual), "baseline_cost_ore": .number(actual + saved), "flat_cost_ore": .number(actual + saved),
            "baseline_house_ore": .number(actual + saved), "baseline_ev_ore": 0,
            "saved_ore": .number(saved),
            "self_consumption_cost_ore": .number(actual + selfSaved), "self_consumption_saved_ore": .number(selfSaved),
            "self_consumption_import_wh": 7_000, "self_consumption_export_wh": 900,
            "expected_ms": 86_400_000, "history_covered_ms": 86_400_000,
            "priced_covered_ms": .number(86_400_000 * coverage),
            "history_coverage_pct": 1, "priced_coverage_pct": .number(coverage),
            "resolution": .string(resolution),
        ]
    }

    static func wire(_ rows: [JSON], totals saved: Double, actual: Double = 20_000, coverage: Double = 1) -> JSON {
        [
            "days": .array(rows),
            "totals": [
                "import_wh": 60_000, "export_wh": 20_000, "load_wh": 90_000,
                "actual_cost_ore": .number(actual), "baseline_cost_ore": .number(actual + saved), "flat_cost_ore": .number(actual + saved),
                "saved_ore": .number(saved),
                "self_consumption_cost_ore": .number(actual - 500), "self_consumption_saved_ore": -500,
                "expected_ms": 600_000_000, "history_covered_ms": 600_000_000, "priced_covered_ms": .number(600_000_000 * coverage),
                "history_coverage_pct": 1, "priced_coverage_pct": .number(coverage),
            ],
            "tz": "Europe/Stockholm", "value_scope": "site_total",
            "baseline": "no_pv_no_battery_vehicle_energy_at_daily_average",
            "baselines": ["no_pv_no_battery", "self_consumption"],
        ]
    }

    static var week: [JSON] {
        (9...15).map { row(String(format: "2026-10-%02d", $0), saved: 1_000) }
    }

    func glance(_ period: Savings.Period, _ wire: JSON, origin: StampOrigin = .relay, asOfMs: Double = SavingsGlanceTests.now) -> SavingsGlance {
        AppWords.$language.withValue(.en) {
            SavingsGlance.make(period: period, answer: Stamped(Savings.answer(wire), asOfMs: asOfMs, origin: origin), nowMs: Self.now, currency: "SEK")
        }
    }

    @Test func todayIsTheBoxsRowAsFarAsItGot() {
        var rows = Self.week
        rows[6] = Self.row("2026-10-15", saved: 912, actual: 2_105)
        let g = glance(.day, Self.wire(rows, totals: 6_912))
        #expect(g.reading.figure == "9.12")
        #expect(g.reading.unit == "kr")
        #expect(g.reading.word == "Saved today so far")
        #expect(g.reading.kicker == nil)
        #expect(g.reading.lines == ["Cost 21.05\u{00A0}kr · with no solar or battery 30.17\u{00A0}kr", "Bought for 26.25\u{00A0}kr, sold for 5.20\u{00A0}kr"])
        #expect(g.footer == "AS OF 14:32")
        // The day's bar stands in full ink among the week, hatched while it fills.
        #expect(g.chart.focus == 6)
        #expect(g.chart.today == 6)
        #expect(g.chart.values.count == 7)
    }

    /// A week is the box's totals, not the app's sum of its days.
    @Test func aWeekIsTheBoxsTotals() {
        let g = glance(.week, Self.wire(Self.week, totals: 6_500, actual: 18_000))
        #expect(g.reading.figure == "65.00")
        #expect(g.reading.word == "Saved 9–15 Oct")
        #expect(g.reading.lines == ["Cost 180\u{00A0}kr · with no solar or battery 245\u{00A0}kr", "Bought 60\u{00A0}kWh, sold 20\u{00A0}kWh"])
        #expect(g.chart.focus == nil)
        #expect(g.chart.landmarks.contains(6))
    }

    @Test func aMonthAcrossNothingButItsOwnDays() {
        let rows = (1...15).map { Self.row(String(format: "2026-10-%02d", $0), saved: Double(500 + 40 * $0)) }
        let g = glance(.month, Self.wire(rows, totals: 12_345))
        #expect(g.reading.figure == "123")
        #expect(g.reading.word == "Saved 1–15 Oct")
        // A month names the first of each week, and today.
        #expect(g.chart.labels.map(\.text) == ["1", "8", "TODAY"])
        // The best day is a landmark for the finger.
        #expect(g.chart.landmarks == [14])
    }

    /// The self-consumption baseline drains the battery and reads cheaper
    /// than what FTW did. The screen never uses it.
    @Test func theSelfConsumptionBaselineIsNeverShown() {
        let rows = (9...15).map { Self.row(String(format: "2026-10-%02d", $0), saved: 1_200, selfSaved: -2_400) }
        for period in Savings.Period.allCases {
            let g = glance(period, Self.wire(rows, totals: 8_400))
            #expect(g.reading.word.hasPrefix("Saved"))
            #expect(!g.reading.word.contains("more"))
            #expect(!g.reading.figure.contains("24"))
            #expect(g.chart.values.allSatisfy { $0 == 1_200 })
        }
    }

    @Test func partialWhenTheBoxPricedLessThanNinetyFivePercent() {
        var rows = Self.week
        rows[6] = Self.row("2026-10-15", saved: 700, coverage: 0.8)
        rows[3] = Self.row("2026-10-12", saved: 900, coverage: 0.96)
        let day = glance(.day, Self.wire(rows, totals: 6_600, coverage: 0.97))
        #expect(day.reading.kicker == "PARTIAL")
        #expect(day.reading.lines.last == "The box had prices for 80\u{00A0}% of the time.")
        #expect(day.chart.partial == [6])
        #expect(day.chart.tags[6] == "TODAY  7.00\u{00A0}KR · PARTIAL")
        let week = glance(.week, Self.wire(rows, totals: 6_600, coverage: 0.97))
        #expect(week.reading.kicker == nil)
        let thin = glance(.week, Self.wire(rows, totals: 6_600, coverage: 0.9))
        #expect(thin.reading.kicker == "PARTIAL")
    }

    @Test func aDayWithNoPricesHasNoMoney() {
        var rows = Self.week
        rows[2] = Self.row("2026-10-11", saved: 0, actual: 0, coverage: 0, resolution: "no_prices")
        let g = glance(.week, Self.wire(rows, totals: 6_000))
        #expect(g.chart.values[2] == nil)
        #expect(g.chart.tags[2] == "SUN 11 OCT  NO PRICES")
        #expect(g.chart.readings[2].figure == "—")
        #expect(!g.chart.readings[2].known)
        #expect(g.chart.readings[2].word == "Saved Sun 11 Oct")
        #expect(g.chart.readings[2].lines == ["The box had no prices then, so it counts no money."])
    }

    /// A day that cost more than a home with no solar or battery says so in
    /// words, below zero, and never with a minus sign.
    @Test func aDayThatCostMoreSaysSoInWords() {
        var rows = Self.week
        rows[6] = Self.row("2026-10-15", saved: -420, actual: 900)
        rows[5] = Self.row("2026-10-14", saved: 300, actual: -150)
        let g = glance(.day, Self.wire(rows, totals: 5_580))
        #expect(g.reading.figure == "4.20")
        #expect(g.reading.word == "Cost more today so far")
        #expect(g.reading.lines.first == "Cost 9.00\u{00A0}kr · with no solar or battery 4.80\u{00A0}kr")
        // Selling more than buying is earning, in words too.
        #expect(g.chart.readings[5].lines.first == "Earned 1.50\u{00A0}kr · with no solar or battery 1.50\u{00A0}kr")
        #expect(g.chart.values[6] == -420)
        #expect(g.chart.bottom == "5 kr")
        let all = [g.reading.figure, g.reading.word] + g.reading.lines + g.chart.tags + [g.chart.top, g.chart.bottom ?? ""]
        #expect(all.allSatisfy { !$0.contains("-") && !$0.contains("−") })
        #expect(AppWords.$language.withValue(.en) { SavingsGlance.row(Stamped(Savings.answer(Self.wire(rows, totals: 0)), asOfMs: Self.now, origin: .relay), nowMs: Self.now, currency: "SEK") } == "cost 4.20\u{00A0}kr more today")
    }

    /// What the last launch kept says when it was true, and that it is the
    /// phone's copy; yesterday's answer names its day, never "today".
    @Test func aKeptAnswerIsDated() {
        let yesterday = Self.now - 15 * 3_600_000
        let rows = (8...14).map { Self.row(String(format: "2026-10-%02d", $0), saved: 1_100) }
        let g = glance(.day, Self.wire(rows, totals: 7_700), origin: .cache, asOfMs: yesterday)
        #expect(g.footer == "SAVED ON THIS PHONE · AS OF WED 23:32")
        #expect(g.reading.word == "Saved Wed 14 Oct")
        #expect(g.chart.today == nil)
        #expect(SavingsGlance.row(Stamped(Savings.answer(Self.wire(rows, totals: 7_700)), asOfMs: yesterday, origin: .cache), nowMs: Self.now, currency: "SEK") == nil)
    }

    @Test func aBoxWithNoPriceAreaSaysWhatItNeeds() {
        let g = glance(.week, ["days": [], "tz": "Europe/Stockholm", "value_scope": "site_total"])
        #expect(g.reading.figure == "—")
        #expect(g.reading.lines == ["Your box counts savings once it knows your price area."])
        #expect(g.chart.isEmpty)
    }

    @Test func beforeAnyAnswerTheShapeWaits() {
        let g = AppWords.$language.withValue(.en) { SavingsGlance.make(period: .week, answer: nil, nowMs: Self.now, currency: "SEK") }
        #expect(g.placeholder)
        #expect(g.chart.isEmpty)
        let failed = AppWords.$language.withValue(.en) { SavingsGlance.make(period: .week, answer: nil, problem: "Your box didn't answer. Still trying.", nowMs: Self.now, currency: "SEK") }
        #expect(!failed.placeholder)
        #expect(failed.reading.figure == "—")
        #expect(failed.reading.lines == ["Your box didn't answer. Still trying."])
    }

    @Test func inSwedish() {
        var rows = Self.week
        rows[6] = Self.row("2026-10-15", saved: 1_840, actual: 3_370, coverage: 0.8)
        let g = AppWords.$language.withValue(.sv) {
            SavingsGlance.make(period: .day, answer: Stamped(Savings.answer(Self.wire(rows, totals: 7_840)), asOfMs: Self.now, origin: .relay), nowMs: Self.now, currency: "SEK")
        }
        #expect(g.reading.figure == "18,40")
        #expect(g.reading.word == "Sparat hittills i dag")
        #expect(g.reading.kicker == "DELVIS")
        #expect(g.reading.lines == ["Kostade 33,70\u{00A0}kr · utan sol och batteri 52,10\u{00A0}kr", "Boxen hade priser för 80\u{00A0}% av tiden."])
        #expect(g.footer == "PER 14:32")
        #expect(g.chart.tags[0] == "FRE 9 OKT  10,00\u{00A0}KR")
        #expect(g.chart.labels.map(\.text) == ["FRE", "LÖR", "SÖN", "MÅN", "TIS", "ONS", "I DAG"])
        let week = AppWords.$language.withValue(.sv) {
            SavingsGlance.make(period: .week, answer: Stamped(Savings.answer(Self.wire(rows, totals: 7_840)), asOfMs: Self.now, origin: .relay), nowMs: Self.now, currency: "SEK")
        }
        #expect(week.reading.word == "Sparat 9–15 okt")
        #expect(AppWords.$language.withValue(.sv) { Savings.Period.allCases.map(\.label) } == ["Dag", "Vecka", "Månad"])
    }

    @Test func aWeekAcrossTwoMonthsNamesBoth() {
        let rows = ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"].map { Self.row($0, saved: 800) }
        let g = glance(.week, Self.wire(rows, totals: 5_600))
        #expect(g.reading.word == "Saved 28 Sep–4 Oct")
    }

    /// Every word the screen hands to AppWords has Swedish. Read from the
    /// source, so a new sentence without Swedish fails here.
    @Test func everyWordHasSwedish() throws {
        let source = try RepoFiles.read("appleApp/FTWKit/Sources/FTWKit/Format/Savings.swift")
            + RepoFiles.read("appleApp/FTW/UI/SavingsView.swift")
        let call = #/(?:AppWords\.(?:text|format)|\bL)\("((?:[^"\\]|\\.)*)"/#
        var english = Set(source.matches(of: call).map { String($0.1) })
        // Picked by a ternary inside a call: the call sees only the first.
        english.formUnion(["%@ today", "cost %@ more today"])
        #expect(english.count > 20)
        for en in english.sorted() {
            #expect(AppWords.sv[en] != nil || NodeWords.sv[en] != nil, "no Swedish for \"\(en)\"")
        }
    }
}

// MARK: The model

@MainActor
@Suite struct SavingsModelTests {
    func sealed() -> SealedFiles {
        SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-savings-\(UUID().uuidString)"), store: MemoryStore())
    }

    func savingsAsks(_ w: ReturnRig, since from: Int = 0) -> Int {
        w.asks(since: from).filter { $0 == "GET /api/savings/daily" }.count
    }

    /// Nothing is asked while nobody looks. The screen asks once for the
    /// week and once for the month, and again only when the quarter hour
    /// has moved on. Hours hidden ask nothing.
    @Test func itAsksByTheDataAgeAndNeverOnATimer() async throws {
        let w = ReturnRig()
        w.dial()
        await w.run(3_000)
        #expect(savingsAsks(w) == 0)

        w.home.savings.activate(month: true)
        await w.run(2_000)
        #expect(savingsAsks(w) == 2)
        let week = try #require(w.home.savings.week)
        #expect(week.origin == .relay)
        #expect(week.value.days.count == 7)
        #expect(w.home.savings.month?.value.days.count == Savings.monthDays(w.scheduler.nowMs, calendar: .household("Europe/Stockholm")))

        // Leaving and coming back in the same quarter asks nothing.
        w.home.savings.deactivate(month: true)
        await w.run(60_000, step: 1_000)
        w.home.savings.activate(month: true)
        await w.run(2_000)
        #expect(savingsAsks(w) == 2)

        // Two hours hidden: no timer asked.
        w.home.savings.deactivate(month: true)
        await w.run(2 * 3_600_000, step: 10_000)
        #expect(savingsAsks(w) == 2)

        // Looking again in a later quarter asks again.
        let before = w.box.asks.count
        w.home.savings.activate()
        await w.run(2_000)
        #expect(savingsAsks(w, since: before) == 1)
    }

    /// A second launch opens on the last answer, dated and marked as the
    /// phone's copy, before it has asked the box anything.
    @Test func itOpensOnTheLastAnswer() async throws {
        let files = sealed()
        let first = ReturnRig(files: files)
        first.dial()
        first.home.savings.activate(month: true)
        await first.run(3_000)
        let said = try #require(first.home.savings.week)
        first.site.suspend()
        first.site.destroy()

        let second = ReturnRig(files: files, nowMs: first.scheduler.nowMs + 5 * 60_000)
        let kept = try #require(second.home.savings.week)
        #expect(kept.origin == .cache)
        #expect(kept.value == said.value)
        #expect(kept.asOfMs == said.asOfMs)
        #expect(second.home.savings.month != nil)
        #expect(second.box.asks.isEmpty)
        let g = AppWords.$language.withValue(.en) {
            SavingsGlance.make(period: .day, answer: kept, nowMs: second.scheduler.nowMs, currency: "SEK")
        }
        #expect(!g.placeholder)
        #expect(g.footer.hasPrefix("SAVED ON THIS PHONE · AS OF"))

        // The box's answer replaces it in place.
        second.dial()
        second.home.savings.activate()
        await second.run(3_000)
        #expect(second.home.savings.week?.origin == .relay)
    }

    /// The demo box's figures add up the way Core's do, so the demo shows
    /// what a real box would.
    @Test func theDemoBoxAnswersInCoresShape() async throws {
        let w = ReturnRig()
        w.dial()
        w.home.savings.activate(month: true)
        await w.run(3_000)
        let a = try #require(w.home.savings.week?.value)
        let t = try #require(a.totals)
        #expect(t.priced)
        #expect(abs(t.savedMinor - (t.baselineMinor - t.actualMinor)) < 1)
        for d in a.days {
            #expect(abs(d.savedMinor - (d.baselineMinor - d.actualMinor)) < 1)
            #expect(d.boughtMinor != nil && d.soldMinor != nil)
        }
        #expect(a.tz == "Europe/Stockholm")
    }
}
