import Foundation

/// The words FTWShared puts on screen, in English or Swedish.
///
/// The English sentence is the key, so a missing translation shows English
/// rather than a code. Swedish lives in `Resources/sv.lproj`. The app and
/// the widget list both languages in `CFBundleLocalizations`; without that,
/// iOS shows a package in the app's development language only.
enum Words {
    static var bundle: Bundle { .module }

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), arguments: args)
    }

    /// The language the words resolve to, for the names the system spells,
    /// such as weekdays, so a Swedish sentence never names an English day.
    static var locale: Locale {
        Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
    }

    /// "65,5" in Swedish, "65.5" in English: a figure written with a point
    /// takes the language's own decimal mark.
    static func decimal(_ text: String) -> String {
        let mark = locale.decimalSeparator ?? "."
        return mark == "." ? text : text.replacingOccurrences(of: ".", with: mark)
    }
}
