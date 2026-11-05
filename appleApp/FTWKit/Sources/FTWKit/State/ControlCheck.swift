import Foundation
import FTWShared
import Observation

/// The box's own answer to "Are we in control?": `control_feedback` from
/// GET /api/status, one row per device function. The status line says when
/// a device needs a look, and the control sheet says why.
///
/// Core works the answer out only when asked, so the phone asks while a
/// home's bar is on screen, and only when the answer may have changed: on
/// looking, once the last answer is a minute old; when the stream says
/// something that changes it (dispatch blocked or freed, a device going
/// quiet or coming back, a new mode); at each new quarter and each new
/// plan, when FTW's targets move; when the battery's or the car's power
/// moved since the answer; and once more when a device was still within
/// the time Core gives it to respond. Never on a timer.
@Observable
@MainActor
public final class ControlCheck {
    public private(set) var rows: [ControlRow] = []
    /// When the box last answered, by the phone clock.
    public private(set) var readAtMs: Double?
    /// The last read failed, with a sentence to show.
    public private(set) var problem: String?
    /// Since when a bar has been on screen; nil while none is.
    public private(set) var lookingSinceMs: Double?

    /// An answer stands this long for someone who starts looking.
    static let standsMs: Double = 60_000
    /// Power that moved this much since the answer asks again.
    nonisolated static let moveW: Double = 500
    nonisolated static let moveShare = 0.3
    /// Never more often than this for a move, however far it went.
    static let minGapMs: Double = 15_000
    /// Core's wait for a device to respond, and a little more.
    nonisolated static let respondsMs: Double = 20_000
    nonisolated static let carRespondsMs: Double = 130_000

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var looking = 0
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var token: Int?
    /// Bumped when power moved or a response was due, so the next look
    /// at the name asks again.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var wattsAtRead: [Int: Double] = [:]
    @ObservationIgnored private var followUp: Cancellable?

    public init(site: SiteModel) {
        self.site = site
    }

    /// The stream's facts behind the answer. A new key is a reason to ask
    /// again.
    public var key: String {
        let s = site.session
        let quiet = s.sources.filter { $0.value.state != .live }.keys.sorted().joined(separator: ",")
        let mode = s.fields[Contract.FID.mode].map { String(Int($0)) } ?? "-"
        return "\(s.phase == .streaming) \(s.dispatchBlockedBy.joined(separator: ",")) \(quiet) \(mode)"
    }

    /// The box answers only over its own API, on a session that streams.
    public var canRead: Bool { site.session.phase == .streaming && site.hasPassthrough }

    /// The answer is current while the session streams; a sheet left open
    /// on a dropped session says so, as the box's page does.
    public var live: Bool { readAtMs != nil && site.session.phase == .streaming }

    /// The rows the owner should look at, while the answer is current:
    /// Core's warnings and alarms. An answer from before someone started
    /// looking stands only as long as it would be asked again.
    public var attention: [ControlRow] {
        guard live, let since = lookingSinceMs, let at = readAtMs, at >= since - Self.standsMs else { return [] }
        return rows.filter { $0.severity == "warning" || $0.severity == "alarm" }
    }

    /// A home's bar came on screen.
    public func activate() {
        looking += 1
        guard looking == 1 else { return }
        lookingSinceMs = site.scheduler.nowMs
        token = site.observe { [weak self] in self?.moved() }
        ask = LiveAsk(site: site, order: .status, ttlMs: Self.standsMs, want: { [weak self] in self?.wanted }, ask: { [weak self] in try await self?.fetch() })
        ask?.evaluate()
    }

    public func deactivate() {
        looking = max(0, looking - 1)
        guard looking == 0 else { return }
        ask?.stop()
        ask = nil
        if let token { site.unobserve(token) }
        token = nil
        followUp?.cancel()
        lookingSinceMs = nil
    }

    /// What the answer is named by: it stands while the stream's facts,
    /// the quarter and the plan hold, and nothing moved.
    private var wanted: String? {
        guard looking > 0, site.hasPassthrough else { return nil }
        let quarter = Int(site.scheduler.nowMs / 900_000)
        return "\(key) q\(quarter) p\(site.session.plan?.rev ?? 0) e\(epoch)"
    }

    private func moved() {
        guard let at = readAtMs, site.scheduler.nowMs - at >= Self.minGapMs else { return }
        let fields = site.session.fields
        if Self.moved(wattsAtRead, fields) {
            epoch += 1
            ask?.evaluate()
        }
    }

    /// Whether the battery or the car moved enough since the answer to
    /// change it.
    nonisolated static func moved(_ before: [Int: Double], _ now: [Int: Double]) -> Bool {
        [Contract.FID.batteryW, Contract.FID.evW].contains { fid in
            guard let w = now[fid] else { return false }
            let was = before[fid] ?? 0
            return abs(w - was) > max(moveW, abs(was) * moveShare)
        }
    }

    /// When to ask again for a device still within its time to respond,
    /// from now; nil when none is.
    nonisolated static func followUpMs(_ rows: [ControlRow]) -> Double? {
        rows.filter { $0.reason == "waiting_response" }
            .map { $0.kind == "ev" ? carRespondsMs : respondsMs }
            .max()
    }

    /// Asked by the control sheet as it opens.
    public func read() async {
        try? await fetch()
    }

    private func fetch() async throws {
        guard canRead else { return }
        generation += 1
        let mine = generation
        let fields = site.session.fields
        do {
            let status = try await site.callBox(.get, "/api/status")
            guard mine == generation else { return }
            rows = ControlRow.rows(status)
            readAtMs = site.scheduler.nowMs
            problem = nil
            wattsAtRead = fields
            followUp?.cancel()
            if let wait = Self.followUpMs(rows), looking > 0 {
                followUp = site.scheduler.after(wait) { [weak self] in
                    guard let self else { return }
                    self.epoch += 1
                    self.ask?.evaluate()
                }
            }
        } catch let e as BoxAPIError {
            guard mine == generation else { return }
            problem = e.help
            throw e
        } catch {
            guard mine == generation else { return }
            problem = AppWords.text("Your box didn't answer. Still trying.")
            throw error
        }
    }
}
