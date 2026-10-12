import ActivityKit
import Foundation
import FTWKit
import FTWShared
import os

/// The Live Activity "Charging now", on ActivityKit. `LoadpointsModel`
/// decides when it starts, moves and ends, from the box's answers; this
/// only carries that out. Local: nothing pushes to it until M7, so its
/// stale date says how long one confirmation is good for.
@MainActor
final class ChargeNowActivities: ChargeNowHost {
    private let log = Logger(subsystem: "energy.ftw.app", category: "live-activity")

    func current(home: String, loadpointID: String) -> ChargeNowActivity.State? {
        Self.live(home, loadpointID).first?.content.state
    }

    func apply(_ action: ChargeNowActivity.Action, home: String, loadpointID: String, zone: TimeZone) {
        switch action {
        case .start(let state):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                log.notice("Live Activities are off for FTW")
                return
            }
            do {
                let attributes = ChargeNowAttributes(home: home, loadpointID: loadpointID, zone: zone)
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: state.staleDate), pushType: nil)
                log.info("charging now: started")
            } catch {
                log.error("charging now: could not start: \(error.localizedDescription, privacy: .public)")
            }
        case .update(let state):
            Task { await Self.update(home, loadpointID, to: state) }
        case .end:
            Task { await Self.end(home, loadpointID) }
            log.info("charging now: ended")
        case .none:
            break
        }
    }

    private nonisolated static func update(_ home: String, _ loadpointID: String, to state: ChargeNowActivity.State) async {
        for activity in live(home, loadpointID) {
            await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
        }
    }

    /// Back to the plan: gone at once, not left on the Lock Screen.
    private nonisolated static func end(_ home: String, _ loadpointID: String) async {
        for activity in live(home, loadpointID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func live(_ home: String, _ loadpointID: String) -> [Activity<ChargeNowAttributes>] {
        Activity<ChargeNowAttributes>.activities.filter {
            $0.attributes.home == home && $0.attributes.loadpointID == loadpointID && ($0.activityState == .active || $0.activityState == .stale)
        }
    }
}
