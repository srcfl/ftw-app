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

    /// The sealed recovery copy. Its own host, neither the relay's nor the app's.
    public static let escrowURL = URL(string: "https://escrow.ftw.energy")!

    /// Source and licence, as the AGPL asks a network client to offer them.
    public static let sourceURL = URL(string: "https://github.com/srcfl/ftw-app")!
    public static let licenseURL = URL(string: "https://github.com/srcfl/ftw-app/blob/main/LICENSE")!
}
