import ActivityKit
import Foundation
import FTWKit
import FTWShared
import os
import WidgetKit

/// Charge now outside the app: the Live Activity on ActivityKit and the
/// Control on WidgetKit. `LoadpointsModel` decides when the Live Activity
/// starts, moves and ends, from the box's answers; this only carries that
/// out. Local: nothing pushes to it until M7, so its stale date says how
/// long one confirmation is good for.
@MainActor
final class ChargeNowActivities: ChargeNowHost {
    private let log = Logger(subsystem: "energy.ftw.app", category: "live-activity")

    func current(home: String, loadpointID: String) -> ChargeNowActivity.State? {
        Self.live { $0.home == home && $0.loadpointID == loadpointID }.first?.content.state
    }

    func loadpointIDs(home: String) -> [String] {
        Self.live { $0.home == home }.map(\.attributes.loadpointID)
    }

    func apply(_ action: ChargeNowActivity.Action, home: String, loadpointID: String, zone: TimeZone) {
        #if DEBUG
        if Self.heldBack(action) { return }
        #endif
        switch action {
        case .start(var state):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                log.notice("Live Activities are off for FTW")
                return
            }
            #if DEBUG
            state = Self.screenshotState(state)
            #endif
            start(state, home: home, loadpointID: loadpointID, zone: zone)
        case .update(let state):
            #if DEBUG
            // The stale screenshot keeps its old confirmation.
            if UserDefaults.standard.bool(forKey: "FTWDemoStaleActivity") { return }
            #endif
            Task { await Self.update(where: { $0.home == home && $0.loadpointID == loadpointID }, to: state) }
        case .end:
            Task { await Self.end(where: { $0.home == home && $0.loadpointID == loadpointID }) }
            log.info("charge now: ended")
        case .none:
            break
        }
    }

    func endAll(except home: String?) {
        let others = Self.live { $0.home != home }
        guard !others.isEmpty else { return }
        log.info("charge now: ending \(others.count, privacy: .public) from another home")
        Task { await Self.end(where: { $0.home != home }) }
    }

    func holdChanged() {
        ControlCenter.shared.reloadControls(ofKind: ChargeNowControlState.kind)
        log.info("charge now: control reloaded")
    }

    private func start(_ state: ChargeNowActivity.State, home: String, loadpointID: String, zone: TimeZone) {
        var staleDate = state.staleDate
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FTWDemoStaleActivity") { staleDate = .now.addingTimeInterval(20) }
        #endif
        do {
            let attributes = ChargeNowAttributes(home: home, loadpointID: loadpointID, zone: zone)
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: nil)
            log.info("charge now: started")
        } catch {
            log.error("charge now: could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func update(where match: @Sendable (ChargeNowAttributes) -> Bool, to state: ChargeNowActivity.State) async {
        for activity in live(match) {
            await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
        }
    }

    /// Gone at once, not left on the Lock Screen.
    private nonisolated static func end(where match: @Sendable (ChargeNowAttributes) -> Bool) async {
        for activity in live(match) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func live(_ match: (ChargeNowAttributes) -> Bool) -> [Activity<ChargeNowAttributes>] {
        Activity<ChargeNowAttributes>.activities.filter {
            match($0.attributes) && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    #if DEBUG
    /// For screenshots: `-FTWDemoPhase sent` or `received` keeps the Live
    /// Activity at that step, which otherwise lasts under a second.
    private static func heldBack(_ action: ChargeNowActivity.Action) -> Bool {
        guard let name = UserDefaults.standard.string(forKey: "FTWDemoPhase"),
              let hold = ChargeNowActivity.State.Phase(rawValue: name) else { return false }
        let order = ChargeNowActivity.State.Phase.allCases
        switch action {
        case .start(let s), .update(let s): return order.firstIndex(of: s.phase)! > order.firstIndex(of: hold)!
        case .end, .none: return true
        }
    }

    /// For screenshots: `-FTWDemoStaleActivity YES` starts the Live
    /// Activity as if Charge now had been on for 25 minutes, and lets it go
    /// stale 20 seconds later instead of 15 minutes, with no read to
    /// confirm it again. The system shows a Live Activity that starts stale
    /// not at all, so it has to become stale on screen, as it would.
    private static func screenshotState(_ state: ChargeNowActivity.State) -> ChargeNowActivity.State {
        guard UserDefaults.standard.bool(forKey: "FTWDemoStaleActivity") else { return state }
        return ChargeNowActivity.State(startedAtMs: state.startedAtMs - 25 * 60_000, confirmedAtMs: state.confirmedAtMs)
    }
    #endif
}
