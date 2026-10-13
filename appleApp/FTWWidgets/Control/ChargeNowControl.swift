import AppIntents
import FTWShared
import os
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "energy.ftw.app", category: "control")

/// Charge now, as a switch in Control Center, on the Lock Screen and on the
/// Action button. iPhone's controls also appear on a paired Apple Watch on
/// watchOS 26, where a press runs on the iPhone.
///
/// The tile shows what the box last confirmed, read from the car record the
/// app leaves in the App Group, never the tap: on, off, no car, or "open FTW
/// to check" once the record is too old to vouch for. On sends Charge now,
/// off Back to the plan. Its intent is a Live Activity intent, so the system
/// runs it in the app, which holds the key that reaches the box. When the
/// command does not happen, FTW opens and says why.
struct ChargeNowControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ChargeNowControlState.kind, provider: ChargeNowValue()) { state in
            ControlWidgetToggle(isOn: state.isOn, action: SetChargeNowIntent()) {
                Text(ChargeNowActivity.title)
                Text(state.label)
            } valueLabel: { isOn in
                Label(state.label, systemImage: isOn ? "bolt.car.fill" : "bolt.car")
                    .controlWidgetActionHint(isOn ? ChargeNowActivity.backToPlan : ChargeNowActivity.title)
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: ChargeNowActivity.title))
        .description(LocalizedStringResource(stringLiteral: ChargeNowActivity.summary))
    }
}

/// The tile's state, from the App Group's car record and its age.
struct ChargeNowValue: ControlValueProvider {
    var previewValue: ChargeNowControlState { ChargeNowControlState(known: .off) }

    func currentValue() async throws -> ChargeNowControlState {
        let reader = CacheReader.shared()
        let read = reader.flatMap { r in r.latestSiteID(CarEntry.self).flatMap { r.read(CarEntry.self, siteId: $0) } }
        let state = ChargeNowControlState.from(read, nowMs: Date.now.timeIntervalSince1970 * 1000)
        log.info("control read: \(String(describing: state.known), privacy: .public)")
        return state
    }
}
