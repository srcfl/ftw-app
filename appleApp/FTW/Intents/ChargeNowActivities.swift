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
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "FTWDemoSecondActivity") {
                // For screenshots of the island's minimal view, which needs
                // two Live Activities at once.
                start(state, home: "screenshot", loadpointID: "second", zone: zone)
            }
            #endif
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
        do {
            let attributes = ChargeNowAttributes(home: home, loadpointID: loadpointID, zone: zone)
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: state.staleDate), pushType: nil)
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
    /// For screenshots: `-FTWDemoStaleActivity YES` starts the Live
    /// Activity as if the box last confirmed it 16 minutes ago, so the
    /// system shows its stale face at once.
    private static func screenshotState(_ state: ChargeNowActivity.State) -> ChargeNowActivity.State {
        guard UserDefaults.standard.bool(forKey: "FTWDemoStaleActivity") else { return state }
        let confirmed = state.confirmedAtMs - ChargeNowActivity.vouchMs - 60_000
        return ChargeNowActivity.State(startedAtMs: confirmed - 25 * 60_000, confirmedAtMs: confirmed)
    }
    #endif
}
