import AppIntents
import FTWShared
import SwiftUI
import WidgetKit

/// Charge now, as a button in Control Center, on the Lock Screen and on the
/// Action button. iPhone's controls also appear on a paired Apple Watch on
/// watchOS 26, where a press runs on the iPhone.
///
/// The control only draws. Its intent is a Live Activity intent, so the
/// system runs it in the app, which holds the key that reaches the box. If
/// a system ever ran it here, it would send nothing and say "Open FTW to
/// charge now".
struct ChargeNowControl: ControlWidget {
    static let kind = "energy.ftw.charge-now"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ChargeNowIntent()) {
                Label(ChargeNowActivity.title, systemImage: "bolt.car.fill")
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: ChargeNowActivity.title))
        .description(LocalizedStringResource(stringLiteral: ChargeNowActivity.summary))
    }
}

/// The shared intents, listed for this extension's App Intents metadata:
/// a control's intent must be known to the app and to the extension.
struct FTWWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FTWSharedIntents.self] }
}
