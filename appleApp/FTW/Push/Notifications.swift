import FTWKit
import os
import UIKit
import UserNotifications

/// The one UIKit piece besides the camera: Apple hands the push token to an
/// app delegate and nowhere else.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifications.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Notifications.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Notifications.log.notice("push: no token: \(error.localizedDescription, privacy: .public)")
    }
}

/// FTW's notifications on the app's side: the buttons, the token, and what a
/// button does. The words are the extension's (FTWNotify).
@MainActor
enum Notifications {
    static let log = Logger(subsystem: "energy.ftw.app", category: "push")
    /// The center holds its delegate weakly.
    private static let delegate = NotificationButtons()

    /// A development build talks to Apple's sandbox.
    static var environment: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    /// At launch, before a button pressed on the lock screen is handed over.
    static func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories(categories(.preferred()))
        PushTokens.setAsk { await askAndRegister() }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FTWPushRegister") {
            Task { await askAndRegister() }
            return
        }
        #endif
        // Allowed before: a new launch can bring a new token. Nobody is
        // asked here; FTW Cloud asks when it is turned on (PushTokens).
        Task {
            let status = await center.notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional || status == .ephemeral {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    static func askAndRegister() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            log.info("push: notifications \(allowed ? "allowed" : "not allowed", privacy: .public)")
            if allowed { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            log.notice("push: could not ask: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func received(token: Data) {
        #if DEBUG
        log.notice("push token \(token.byteArray.hex, privacy: .public) (\(environment.rawValue, privacy: .public))")
        #endif
        Task { await PushTokens.received(token, environment: environment) }
    }

    /// The level and Charge now run behind the lock screen once the phone is
    /// unlocked; Open brings the app up.
    static func categories(_ language: PushText.Language) -> Set<UNNotificationCategory> {
        Set(PushActions.Category.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: category.actions.map { action in
                    UNNotificationAction(
                        identifier: action.rawValue,
                        title: PushActions.title(action, language),
                        options: PushActions.opensApp(action) ? [.foreground] : [.authenticationRequired],
                        icon: UNNotificationActionIcon(systemImageName: PushActions.symbol(action))
                    )
                },
                intentIdentifiers: []
            )
        })
    }

    /// A button was pressed. The payload is checked again, with the time it
    /// arrived, and the button acts only for a verified event whose kind
    /// offers it, on the charger the event named, in the home this app
    /// opens. The box's answer is logged; nothing here claims more.
    static func act(_ action: PushActions.Action, _ command: RemoteCommand, alert: PushAlert, home: CloudHome?) async {
        guard PushActions.allows(action, for: alert) else {
            log.notice("push: \(action.rawValue, privacy: .public) not sent: \(alert.verdict.rawValue, privacy: .public) \(alert.kind, privacy: .public)")
            return
        }
        guard let home, let loadpointID = home.loadpointID(opaque: alert.lp) else {
            log.notice("push: \(action.rawValue, privacy: .public) not sent: no charger for this event on this phone")
            return
        }
        guard let runner = IntentRunner.shared, runner.opens(siteId: home.siteId) else {
            log.notice("push: \(action.rawValue, privacy: .public) not sent: not the home this app opens")
            return
        }
        let out = await runner.run(command, loadpointID: loadpointID)
        log.info("push: \(action.rawValue, privacy: .public): \(String(describing: out.kind), privacy: .public): \(out.text, privacy: .public)")
    }
}

/// Where the system hands a pressed button and a notification that arrives
/// while FTW is open.
final class NotificationButtons: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // A tap on the notification, Open, or a dismissal asks the box
        // nothing.
        guard let action = PushActions.Action(rawValue: response.actionIdentifier), let command = PushActions.command(action) else { return }
        let keys = CloudKeys.shared()
        let alert = PushAlert.read(
            userInfo: response.notification.request.content.userInfo,
            boxKey: { keys?.boxKey(home: $0) },
            offset: { keys?.offset(home: $0) },
            nowMs: Int64(response.notification.date.timeIntervalSince1970 * 1000)
        )
        await Notifications.act(action, command, alert: alert, home: keys?.read(home: alert.home))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
