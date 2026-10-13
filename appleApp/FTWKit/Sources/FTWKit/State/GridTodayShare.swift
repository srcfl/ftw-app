import Foundation
import FTWShared

/// Leaves today over the grid for the grid widget: the box's totals and cost
/// from `GET /api/savings/daily?days=1`, and the grid's power since midnight
/// from the history the grid's node view draws.
///
/// It reads while the app is open and on screen, once a quarter hour, the
/// step of the widget's chart, and again when the household's day turns.
/// Each read is one record, dated when the totals arrived, and the app wakes
/// the widgets after it lands. No timer runs while the app is hidden: the
/// widget says how old its figures are, and after midnight that they are
/// yesterday's.
@MainActor
public final class GridTodayShare {
    private unowned let site: SiteModel
    private unowned let history: HistoryModel
    private unowned let prices: PriceModel
    private var ask: LiveAsk?

    public init(site: SiteModel, history: HistoryModel, prices: PriceModel) {
        self.site = site
        self.history = history
        self.prices = prices
        // A home that leaves nothing for widgets has nothing to read for.
        guard site.sharesWidgets else { return }
        ask = LiveAsk(site: site, want: { [weak self] in self?.wanted }, ask: { [weak self] in try await self?.load() })
    }

    /// What would make the record out of date: a new quarter hour, or a new
    /// day on the household's clock.
    var wanted: String? {
        guard site.documentVisible, site.hasPassthrough else { return nil }
        let day = GridTodayEntry.dayName(site.nowMs, calendar: calendar)
        return "grid today \(day) \(Int(site.nowMs / GridTodayEntry.quarterMs))"
    }

    private var calendar: Calendar { .household(site.session.box?.tz) }

    func load() async throws {
        let readAt = site.nowMs
        let wire = try await site.callBox(.get, "/api/savings/daily", query: ["days": "1"])
        // A box with no price zone answers no days at all: nothing to leave.
        guard let row = wire?["days"]?.array?.last, let totals = Self.totals(row) else { return }
        let calendar = self.calendar
        guard let day = GridTodayEntry.bounds(day: totals.day, calendar: calendar) else { return }

        // The history the grid's node view reads. A failure leaves the
        // chart as last read; the totals are written all the same, and the
        // ask comes again.
        var failure: Error?
        if history.available {
            do { try await history.load() } catch { failure = error }
        }
        let steps = history.frame.map { frame in
            HistoryModel.samples(frame, node: .grid, fromMs: day.startMs).map { (startMs: $0.startMs, stepMs: $0.stepMs, watts: $0.watts) }
        } ?? []
        let entry = GridTodayEntry(
            day: totals.day,
            dayStartMs: day.startMs,
            dayEndMs: day.endMs,
            importWh: totals.importWh,
            exportWh: totals.exportWh,
            costMinor: totals.costMinor,
            pricedCoverage: totals.pricedCoverage,
            currency: prices.currency,
            timeZone: site.session.box?.tz,
            quarters: GridTodayEntry.quarters(steps, dayStartMs: day.startMs, untilMs: min(day.endMs, site.nowMs))
        )
        site.shareGridToday(entry, readAtMs: readAt, srcState: site.freshness(.grid).srcState)
        if let failure { throw failure }
    }

    struct Totals: Equatable {
        let day: String
        let importWh: Double
        let exportWh: Double
        let costMinor: Double?
        let pricedCoverage: Double
    }

    /// One row of the box's answer, as it gave it. The cost is the box's own
    /// `actual_cost_ore`, import cost less export revenue; a day the box had
    /// no prices for has none.
    static func totals(_ row: JSON) -> Totals? {
        guard let day = row["day"]?.string, day.count == 10 else { return nil }
        let priced = row["resolution"]?.string != "no_prices"
        return Totals(
            day: day,
            importWh: EnergyFormat.wholeWh(row["import_wh"]?.number),
            exportWh: EnergyFormat.wholeWh(row["export_wh"]?.number),
            costMinor: priced ? row["actual_cost_ore"]?.number : nil,
            pricedCoverage: min(1, max(0, row["priced_coverage_pct"]?.number ?? 0))
        )
    }
}
