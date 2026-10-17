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

// MARK: Which car?

extension PushActions {
    /// "Which car?" gets one button per car the box offers and "None of
    /// these", with the names from the phone's own table. A category's
    /// buttons are fixed when the app registers it, so the app registers
    /// one for each set of the owner's cars (`carCategories`) and the
    /// extension picks the set an event offers.
    public static let carPrefix = "ftw.car."
    public static let carNone = "ftw.car.none"
    static let carCategoryPrefix = "ftw.car.which."
    /// The most cars whose every set gets a category: 63 of them.
    public static let carSetMax = 6
    /// docs/cars.md: at most four buttons, else none and the tap opens FTW.
    public static let carButtonsMax = 4

    /// A category for each set of up to four of `cars`, each in their order.
    public static func carCategories(_ cars: [CloudHome.Car]) -> [(id: String, cars: [CloudHome.Car])] {
        guard !cars.isEmpty, cars.count <= carSetMax else { return [] }
        return (1..<(1 << cars.count)).compactMap { mask in
            let set = cars.indices.filter { mask & (1 << $0) != 0 }.map { cars[$0] }
            return set.count <= carButtonsMax ? (carCategoryPrefix + String(mask), set) : nil
        }
    }

    /// The category a verified `car.which` gets: the set of cars it offers,
    /// when the phone knows each of them. Nil gives no buttons.
    public static func carCategory(for alert: PushAlert, home: CloudHome?) -> String? {
        guard alert.verdict == .event, alert.kind == PushKind.carWhich, let cars = home?.cars, cars.count <= carSetMax,
              !alert.cars.isEmpty, alert.cars.count <= carButtonsMax else { return nil }
        var mask = 0
        for opaque in alert.cars {
            guard let i = cars.firstIndex(where: { $0.opaque == opaque }) else { return nil }
            mask |= 1 << i
        }
        return carCategoryPrefix + String(mask)
    }

    /// A car's button; nil is "None of these".
    public static func carAction(_ carID: String?) -> String { carID.map { carPrefix + $0 } ?? carNone }

    /// The car a button names: its id, "" for None of these, nil for any
    /// other button.
    public static func carChoice(_ actionID: String) -> String? {
        if actionID == carNone { return "" }
        guard actionID.hasPrefix(carPrefix) else { return nil }
        let id = String(actionID.dropFirst(carPrefix.count))
        return id.count == 32 && id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) ? id : nil
    }

    /// Whether a car's button may run: a verified `car.which` that offered
    /// that car. None of these is always one of its buttons.
    public static func allowsCar(_ carID: String, for alert: PushAlert, home: CloudHome?) -> Bool {
        guard alert.verdict == .event, alert.kind == PushKind.carWhich, carCategory(for: alert, home: home) != nil else { return false }
        if carID.isEmpty { return true }
        guard let car = home?.cars?.first(where: { $0.id == carID }) else { return false }
        return alert.cars.contains(car.opaque)
    }

    public static func noneTitle(_ language: PushText.Language) -> String {
        language == .sv ? "Ingen av dessa" : "None of these"
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
        category = PushActions.category(for: alert)?.rawValue ?? PushActions.carCategory(for: alert, home: home) ?? ""
        level = Self.level(alert)
        thread = alert.home
        verified = alert.verdict == .generic ? [:] : ["verdict": alert.verdict.rawValue, "home": alert.home]
        if alert.verdict == .event {
            verified["kind"] = alert.kind
            verified["seq"] = String(alert.seq)
            verified["atMs"] = String(alert.atMs)
            if let lp = home?.loadpointID(opaque: alert.lp) { verified["loadpointID"] = lp }
            if let session = alert.args["session"], alert.kind == PushKind.carWhich { verified["session"] = session }
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
