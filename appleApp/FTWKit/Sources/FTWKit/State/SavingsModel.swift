import Foundation
import FTWShared
import Observation

/// What the home saved, from `GET /api/savings/daily`: the last seven days,
/// for the day and the week, and the month so far. Each is the box's answer
/// as it gave it, with its totals.
///
/// Opens on what the last launch kept, dated. Asks only while someone
/// looks, and only when the quarter hour has moved on since the last
/// answer: today's figures grow with the box's ledger, and a quarter is as
/// fresh as a glance needs. No timer runs.
@Observable
@MainActor
public final class SavingsModel: Activatable {
    /// The last seven days, today last.
    public private(set) var week: Stamped<Savings.Answer>?
    /// The month so far, today last.
    public private(set) var month: Stamped<Savings.Answer>?
    /// Why nothing has come, while nothing has.
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var weekAsk: LiveAsk?
    @ObservationIgnored private var monthAsk: LiveAsk?
    @ObservationIgnored private var looking = 0
    @ObservationIgnored private var lookingAtMonth = 0

    /// What this model keeps between launches, beside the home file.
    struct File: Codable, Equatable {
        static let version = 1
        var version = File.version
        var week: Stamped<Savings.Answer>?
        var month: Stamped<Savings.Answer>?
    }

    public init(site: SiteModel) {
        self.site = site
        if let kept = site.keptFile(File.self, "savings"), kept.version == File.version {
            week = kept.week?.cached
            month = kept.month?.cached
        }
        // Written as a later launch reads it, so reading it back changes
        // nothing.
        site.keepFile("savings") { [weak self] () -> File? in
            guard let self, self.week != nil || self.month != nil else { return nil }
            return File(week: self.week?.cached, month: self.month?.cached)
        }
    }

    /// The home node's row reads the week. The savings screen reads the
    /// month too, so its picker never waits.
    public func activate() { activate(month: false) }
    public func deactivate() { deactivate(month: false) }

    public func activate(month: Bool) {
        looking += 1
        if month { lookingAtMonth += 1 }
        if weekAsk == nil {
            weekAsk = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.looking > 0 else { return nil }
                return self.name(days: 7)
            }, ask: { [weak self] in try await self?.load(days: 7, into: \.week) })
        }
        if monthAsk == nil {
            monthAsk = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.lookingAtMonth > 0 else { return nil }
                return self.name(days: self.monthDays)
            }, ask: { [weak self] in
                guard let self else { return }
                try await self.load(days: self.monthDays, into: \.month)
            })
        }
        weekAsk?.evaluate()
        monthAsk?.evaluate()
    }

    public func deactivate(month: Bool) {
        looking = max(0, looking - 1)
        if month { lookingAtMonth = max(0, lookingAtMonth - 1) }
        weekAsk?.evaluate()
        monthAsk?.evaluate()
    }

    private var calendar: Calendar { .household(site.session.box?.tz) }
    private var monthDays: Int { Savings.monthDays(site.nowMs, calendar: calendar) }

    /// The span and the quarter hour on the phone's clock: a new quarter,
    /// or a new day, makes the last answer old.
    private func name(days: Int) -> String? {
        guard site.hasPassthrough else { return nil }
        return "savings \(days) \(Int(site.nowMs / 900_000))"
    }

    func load(days: Int, into slot: ReferenceWritableKeyPath<SavingsModel, Stamped<Savings.Answer>?>) async throws {
        do {
            let wire = try await site.callBox(.get, "/api/savings/daily", query: ["days": String(days)])
            let next = Stamped(Savings.answer(wire), asOfMs: site.nowMs, origin: .relay)
            if let shown = Stamped.taking(next, over: self[keyPath: slot]) { self[keyPath: slot] = shown }
            if problem != nil { problem = nil }
        } catch {
            // What is on screen stays, dated; the ask heals.
            if week == nil, month == nil { problem = (error as? HelpfulError)?.help }
            throw error
        }
    }
}
