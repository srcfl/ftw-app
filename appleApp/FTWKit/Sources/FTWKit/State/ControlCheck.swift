import Foundation
import FTWShared
import Observation

/// The box's own answer to "Are we in control?", for the control sheet:
/// `control_feedback` from GET /api/status, one row per device function.
///
/// Nothing reads it on a timer. The sheet asks when it opens, and again
/// when the stream says something that changes the answer: dispatch
/// blocked or freed, a device going quiet or coming back, a new mode.
@Observable
@MainActor
public final class ControlCheck {
    public private(set) var rows: [ControlRow] = []
    /// When the box last answered, by the phone clock.
    public private(set) var readAtMs: Double?
    /// The last read failed, with a sentence to show.
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var generation = 0

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

    public func read() async {
        guard canRead else { return }
        generation += 1
        let mine = generation
        do {
            let status = try await site.callBox(.get, "/api/status")
            guard mine == generation else { return }
            rows = ControlRow.rows(status)
            readAtMs = site.scheduler.nowMs
            problem = nil
        } catch let e as BoxAPIError {
            guard mine == generation else { return }
            problem = e.help
        } catch {
            guard mine == generation else { return }
            problem = AppWords.text("Your box didn't answer. Still trying.")
        }
    }
}
