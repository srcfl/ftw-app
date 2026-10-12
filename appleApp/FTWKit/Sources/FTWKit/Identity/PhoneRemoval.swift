import Foundation

/// Removing this phone, as far as the phone can reach.
///
/// The registry has no op that lets a phone take itself off its box, so the
/// app does what is in its own hands, `AppModel.leave`: the key, the pairing,
/// the sealed readings and the widgets' records go. It then says how the
/// owner removes the phone on the box. That is also the one way that always
/// works: over a session the box refuses to remove its last owner, and on
/// its own page it allows it.
///
/// FTW creates no account. A pairing is a key on this phone and a row on the
/// household's own box, and this is where both are dealt with.
public enum PhoneRemoval {
    /// The row on the box's Settings → FTW app page, which names each phone
    /// by the first eight characters of its key (`Vault.deviceIDOnBox`).
    /// The box's page is in English, so the name is too.
    public static func nameOnBox(_ deviceID: String) -> String { "Phone \(deviceID)" }

    public static func boxSteps(_ deviceID: String) -> [String] {
        [
            AboutWords.text("Open your box's local dashboard while on your home network."),
            AboutWords.text("Go to Settings → FTW app."),
            AboutWords.format("Choose Remove next to %@.", nameOnBox(deviceID)),
        ]
    }
}
