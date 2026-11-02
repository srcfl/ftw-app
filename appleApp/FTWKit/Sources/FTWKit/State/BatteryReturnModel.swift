import Foundation
import FTWShared
import Observation

/// One calendar year's energy tax refund after battery storage, from
/// `GET /api/energy/battery-return`, and the hourly basis behind it from
/// the `.csv` beside it, for the owner to keep with the application.
///
/// Asks only while the screen is open, for the year on it, and again when
/// the hour turns: the running year grows with the box's ledger, and an
/// ended one changes when the box's battery settings do. Each year's last
/// answer is kept on this phone, so the screen opens on it, dated.
@Observable
@MainActor
public final class BatteryReturnModel: Activatable {
    /// The year on screen. Opens on the last one to have ended.
    public var year: Int {
        didSet { ask?.evaluate() }
    }
    /// Each year's last answer.
    public private(set) var answers: [Int: Stamped<BatteryReturn.Report>] = [:]
    /// Why a year has no answer, while it has none.
    public private(set) var problems: [Int: String] = [:]

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var looking = 0

    /// What this model keeps between launches, beside the home file.
    struct File: Codable, Equatable {
        /// 2: one account per battery, so an answer kept in the old shape
        /// is dropped.
        static let version = 2
        var version = File.version
        var answers: [Int: Stamped<BatteryReturn.Report>]
    }

    public init(site: SiteModel) {
        self.site = site
        year = BatteryReturn.defaultYear(nowMs: site.nowMs)
        if let kept = site.keptFile(File.self, "battery-return"), kept.version == File.version {
            answers = kept.answers.mapValues(\.cached)
        }
        // Written as a later launch reads it, so reading it back changes
        // nothing.
        site.keepFile("battery-return") { [weak self] () -> File? in
            guard let self, !self.answers.isEmpty else { return nil }
            return File(answers: self.answers.mapValues(\.cached))
        }
    }

    /// What the screen says for the year on it.
    public var glance: BatteryReturnGlance {
        BatteryReturnGlance.make(year: year, answer: answers[year], problem: problems[year], nowMs: site.minuteMs)
    }

    /// The years to choose from, newest first.
    public var years: [Int] { BatteryReturn.years(nowMs: site.minuteMs) }

    public func activate() {
        looking += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in self?.wanted }, ask: { [weak self] in
                guard let self else { return }
                try await self.load(self.year)
            })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        looking = max(0, looking - 1)
        ask?.evaluate()
    }

    /// The year and the hour on the phone's clock: another year, or a new
    /// hour, makes the last answer old.
    var wanted: String? {
        guard looking > 0, site.hasPassthrough else { return nil }
        return "battery-return \(year) \(Int(site.nowMs / 3_600_000))"
    }

    func load(_ year: Int) async throws {
        do {
            let wire = try await site.callBox(.get, "/api/energy/battery-return", query: ["year": String(year)])
            guard let report = BatteryReturn.report(wire), report.year == year else {
                throw BoxAPIError(code: "E_BAD_BODY", help: AppWords.text("Your box sent something this app couldn't read."), status: nil)
            }
            let next = Stamped(report, asOfMs: site.nowMs, origin: .relay)
            if let shown = Stamped.taking(next, over: answers[year]) { answers[year] = shown }
            if problems[year] != nil { problems[year] = nil }
        } catch {
            // What is on screen stays, dated; the ask heals.
            if answers[year] == nil { problems[year] = (error as? HelpfulError)?.help }
            throw error
        }
    }

    /// The hourly basis behind a year's figure, as a file named as the box
    /// names its download, for the share sheet. Read from the box each
    /// time: the box is the record.
    public func basis(_ year: Int) async throws -> URL {
        let bytes = try await site.readBox("/api/energy/battery-return.csv", query: ["year": String(year)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(BatteryReturn.basisName(year))
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }
}
