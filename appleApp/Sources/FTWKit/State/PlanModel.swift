import Foundation
import Observation

/// The plan, and changing how the site is run. The plan lives on session
/// state because the box pushes a fresh one unasked after a mode change
/// made from any phone.
@Observable
@MainActor
public final class PlanModel: Activatable {
    public enum Command: Equatable, Sendable {
        case idle
        case sending(String)
        case applied(String)
        case unconfirmed(String)
        case failed(String)
    }

    /// How long a settled outcome stays before the screen goes quiet.
    static let settleMs: Double = 4_000

    public private(set) var loading = false
    /// A sentence, never a code.
    public private(set) var problem: String?
    public private(set) var command: Command = .idle

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var want = 0
    @ObservationIgnored private var settle: Cancellable?

    public init(site: SiteModel) {
        self.site = site
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0 else { return nil }
                return "plan \(self.want)"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    public var plan: Plan? { site.session.plan }

    /// Every mode the box accepts, in its order. Hidden ones are valid over
    /// the API but never buttons.
    public var modes: [ModeInfo] { site.session.modes.filter { $0.tier != "hidden" } }
    public var primaryModes: [ModeInfo] { modes.filter { $0.tier == "primary" } }
    public var advancedModes: [ModeInfo] { modes.filter { $0.tier == "advanced" } }

    /// The mode the box reports, which is the only one that counts.
    public var actualMode: String? {
        guard let i = site.session.fields[Contract.FID.mode].map({ Int($0) }), i >= 0, i < site.session.modes.count else { return nil }
        return site.session.modes[i].key
    }

    /// The pending choice while one is in flight, else the real one. A
    /// refusal snaps back because this never overrides what the box said.
    public var shownMode: String? {
        switch command {
        case .sending(let m), .applied(let m), .unconfirmed(let m): return m
        default: return actualMode
        }
    }

    public var inManual: Bool {
        guard let m = shownMode else { return false }
        return advancedModes.contains { $0.key == m }
    }

    /// The way back from a manual fallback: the box's first primary mode.
    public var planHome: ModeInfo? { primaryModes.first }

    /// Both have to hold: the box offers dispatch, and this enrolment carries
    /// the scope the box checks. Drawing a control a viewer will be refused
    /// is the one thing this app must not do.
    public var canControl: Bool {
        site.session.caps.contains(Contract.capPlanDispatch) && site.session.scopes.contains(Contract.scopeModeWrite)
    }

    public enum NoControl: Sendable { case box, role }

    /// Nil until the box has answered: before its hello, "this box can't do
    /// that" would be a sentence about a box that has said nothing.
    public var whyNoControl: NoControl? {
        guard site.heardFromBox, !canControl else { return nil }
        return site.session.scopes.contains(Contract.scopeModeWrite) ? .box : .role
    }

    func load() async throws {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            _ = try await site.plan()
        } catch {
            problem = "Couldn't get the plan from your box. Still trying."
            throw error
        }
    }

    /// Optimistic on screen, never in the model.
    public func setMode(_ mode: String) async {
        if case .sending = command { return }
        if mode == shownMode { return }
        settle?.cancel()
        command = .sending(mode)
        do {
            let result = try await site.command(Contract.opSetMode, args: [("mode", .text(mode))])
            switch result.state {
            case .applied:
                command = .applied(mode)
                followPlan()
            case .unconfirmed:
                command = .unconfirmed(mode)
            default:
                command = .failed(CommandText.help(result))
            }
        } catch let e as CommandError {
            command = .failed(e.help)
        } catch {
            command = .failed("That didn't go through. Try again.")
        }
        settle = site.scheduler.after(Self.settleMs) { [weak self] in self?.command = .idle }
    }

    /// The box acknowledges a mode before its optimiser has replanned, so the
    /// plan is asked for again every three seconds, for thirty at most,
    /// until its revision moves.
    private func followPlan() {
        let before = plan?.rev
        func step(_ n: Int) {
            guard n < 10, plan?.rev == before else { return }
            want += 1
            ask?.evaluate()
            site.scheduler.after(3_000) { [weak self] in
                guard self != nil else { return }
                step(n + 1)
            }
        }
        step(0)
    }
}
