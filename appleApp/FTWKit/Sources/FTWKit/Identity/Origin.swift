import Foundation

/// Where FTW lives, decided once. The QR host, the passkey's relying party
/// and the web app's origin are the same string by construction.
public enum Origin {
    /// The one origin, and the host in every pairing QR.
    public static let appHost = "app.ftw.energy"

    /// The passkey relying party. The app subdomain, never the registrable
    /// domain: PRF output is bound to the RP ID, so its scope decides who may
    /// derive the keys. Changing it strands every passkey.
    public static let rpID = appHost
    public static let rpName = "FTW"

    /// The relay. One value, no setting.
    public static let relayURL = URL(string: "wss://relay.ftw.energy")!

    /// The repository. A fork changes this line, as LICENSING.md asks: the
    /// links in Source & licenses must lead to the fork's own source.
    /// `BuildSource` pins them to the build's commit.
    public static let sourceURL = URL(string: "https://github.com/srcfl/ftw-app")!

    /// The privacy policy, which App Review asks to be easy to find in the
    /// app, and the support page beside it. Swedish where the app speaks it.
    public static func privacyURL(_ language: AboutWords.Language = AboutWords.language) -> URL {
        site(language, "privacy")
    }

    public static func supportURL(_ language: AboutWords.Language = AboutWords.language) -> URL {
        site(language, "support")
    }

    private static func site(_ language: AboutWords.Language, _ page: String) -> URL {
        URL(string: "https://ftw.energy/\(language == .sv ? "sv/" : "")\(page)")!
    }
}
