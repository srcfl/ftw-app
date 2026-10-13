import Foundation
import UserNotifications

/// The buttons a push may carry, and what each one asks the box.
///
/// Only a kind the box signed picks them; the service never does, so the
/// extension always sets the category itself, empty when there are none.
/// Every command from a notification needs the phone unlocked (Fredrik,
/// 12 Oct 2026), and runs in the background over the app's own session
/// with the box, as Siri's do.
public enum PushActions {
    public enum Action: String, CaseIterable, Sendable {
        case level20 = "ftw.level.20"
        case level50 = "ftw.level.50"
        case level80 = "ftw.level.80"
        case chargeNow = "ftw.chargeNow"
        case open = "ftw.open"
    }

    public enum Category: String, CaseIterable, Sendable {
        /// The car was plugged in: tell FTW how full it is.
        case level = "ftw.level"
        /// The car may not be ready: start charging at once.
        case chargeNow = "ftw.chargeNow"

        public var actions: [Action] {
            switch self {
            case .level: return [.level20, .level50, .level80, .open]
            case .chargeNow: return [.chargeNow, .open]
            }
        }
    }

    /// Few kinds get buttons, and only from a verified event.
    public static func category(for alert: PushAlert) -> Category? {
        guard alert.verdict == .event else { return nil }
        switch alert.kind {
        case PushKind.chargingConnected: return .level
        case PushKind.chargingInterrupted, PushKind.chargingGoalAtRisk: return .chargeNow
        default: return nil
        }
    }

    /// Whether a button may run for this alert: it has to be one its
    /// verified kind gets.
    public static func allows(_ action: Action, for alert: PushAlert) -> Bool {
        category(for: alert)?.actions.contains(action) ?? false
    }

    /// What the button asks the box. Open asks nothing; it opens the app.
    public static func command(_ action: Action) -> RemoteCommand? {
        switch action {
        case .level20: return .setLevel(pct: 20)
        case .level50: return .setLevel(pct: 50)
        case .level80: return .setLevel(pct: 80)
        case .chargeNow: return .chargeNow
        case .open: return nil
        }
    }

    /// Whether the button needs the app on screen. The others run behind
    /// the lock screen once the phone is unlocked.
    public static func opensApp(_ action: Action) -> Bool {
        action == .open
    }

    public static func title(_ action: Action, _ language: PushText.Language) -> String {
        switch action {
        case .level20: return "20 %"
        case .level50: return "50 %"
        case .level80: return "80 %"
        case .chargeNow: return language == .sv ? "Ladda nu" : "Charge now"
        case .open: return language == .sv ? "Öppna" : "Open"
        }
    }

    public static func symbol(_ action: Action) -> String {
        switch action {
        case .level20: return "battery.25percent"
        case .level50: return "battery.50percent"
        case .level80: return "battery.75percent"
        case .chargeNow: return "bolt.fill"
        case .open: return "arrow.up.forward.app"
        }
    }
}

/// Everything the extension sets on a notification, from one checked alert.
public struct PushNotice: Sendable, Equatable {
    public var title: String
    public var body: String
    /// "" for no buttons. Always set, so a category the service put in the
    /// payload never shows.
    public var category: String
    public var level: UNNotificationInterruptionLevel
    /// Whether it makes a sound.
    public var sound = true
    /// One thread per home.
    public var thread: String
    /// The checked fields, for the app. The app checks the payload again
    /// before it acts and never trusts these alone.
    public var verified: [String: String]

    public init(_ alert: PushAlert, home: CloudHome?, language: PushText.Language, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") {
        let words = PushText.content(alert, sourceName: home?.sourceName(opaque: alert.src), language: language, decimalSeparator: decimalSeparator)
        title = words.title
        body = words.body
        category = PushActions.category(for: alert)?.rawValue ?? ""
        level = Self.level(alert)
        thread = alert.home
        verified = alert.verdict == .generic ? [:] : ["verdict": alert.verdict.rawValue, "home": alert.home]
        if alert.verdict == .event {
            verified["kind"] = alert.kind
            verified["seq"] = String(alert.seq)
            verified["atMs"] = String(alert.atMs)
            if let lp = home?.loadpointID(opaque: alert.lp) { verified["loadpointID"] = lp }
        }
    }

    /// The generic line, for an extension that ran out of time.
    public static func generic(_ language: PushText.Language) -> PushNotice {
        PushNotice(PushAlert(.generic, home: ""), home: nil, language: language)
    }

    /// An event shown before. iOS shows something for every push unless
    /// Apple grants the filtering entitlement, and without it empty content
    /// brings back the payload's own alert. So: the generic line, quiet,
    /// with no buttons, in Notification Center only.
    public static func repeated(_ alert: PushAlert, language: PushText.Language) -> PushNotice {
        var n = PushNotice(PushAlert(.generic, home: alert.home), home: nil, language: language)
        n.level = .passive
        n.sound = false
        return n
    }

    /// The key `verified` sits under in the notification's userInfo.
    public static let userInfoKey = "ftwVerified"

    /// The payload never says how urgent it is. A box out of reach and a
    /// charge that stopped early break through a Focus; the rest wait.
    static func level(_ alert: PushAlert) -> UNNotificationInterruptionLevel {
        switch alert.verdict {
        case .unreachable: return .timeSensitive
        case .event where alert.kind == PushKind.chargingInterrupted: return .timeSensitive
        default: return .active
        }
    }
}
