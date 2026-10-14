import Foundation

extension AppModel {
    /// Now's title: the home's name as this phone keeps it. A home paired
    /// without a name of its own is "Home" in the phone's language.
    public var homeName: String {
        if isDemo { return HomeName.demo }
        return HomeName.title(site?.siteId.flatMap { sites.get($0)?.label })
    }

    /// The homes this phone is paired to, in the order they were paired.
    public var homes: [StoredSite] { sites.all().sorted { $0.addedAtMs < $1.addedAtMs } }
}

public enum HomeName {
    /// The label pairing gives a home that names none.
    static let unnamed = "Home"

    public static func title(_ label: String?) -> String {
        guard let label, !label.isEmpty, label != unnamed else { return AppWords.language == .sv ? "Hem" : "Home" }
        return label
    }

    public static var demo: String { AppWords.language == .sv ? "Demohem" : "Demo home" }
}
