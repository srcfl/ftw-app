import Foundation

/// The words FTWShared puts on screen, in English or Swedish.
///
/// The English sentence is the key, so a missing translation shows English
/// rather than a code. Swedish lives in `Resources/sv.lproj`. The app and
/// the widget list both languages in `CFBundleLocalizations`; without that,
/// iOS shows a package in the app's development language only.
enum Words {
    static func text(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), arguments: args)
    }
}
