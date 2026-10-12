import Foundation

/// From a scanned code to a paired home, in the order that keeps it to two
/// taps and fails before the passkey prompt whenever it can:
///
///   1. Parse the QR. A bad code fails before anyone is asked for Face ID.
///   2. Ask for the passkey, once.
///   3. Unwrap or create the device key, and make the local copy.
///   4. Store the home, pinned to the box key from the QR.
///
/// Only then does anything touch the network.
@MainActor
public final class Pairing {
    private let vault: Vault
    private let sites: SiteList
    private let passkeys: PasskeyAuthenticator?
    private let now: () -> Double

    public init(vault: Vault, sites: SiteList, passkeys: PasskeyAuthenticator?, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.vault = vault
        self.sites = sites
        self.passkeys = passkeys
        self.now = now
    }

    /// Throws `EnrollmentError` with a sentence, or `PasskeyCancelled`.
    public func pair(scanned: String) async throws -> StoredSite {
        let enrollment = try Enrollment.parse(scanned: scanned)

        let wrapping = vault.isEnrolled
            ? try await vault.unlockWrappingKey(passkeys)
            : try await vault.enrollWrappingKey(passkeys)
        _ = try vault.deviceKey(wrapping)
        // The last prompt reading ever costs. PRF keeps guarding enrollment
        // and privileged writes; looking at your own house is not one.
        try vault.ensureLocalCopy(wrapping)

        let at = now()
        let siteId = SiteList.siteID(enrollment.boxStaticPublic)
        let site = StoredSite(
            siteId: siteId,
            label: sites.get(siteId)?.label ?? "Home",
            boxStaticKey: Data(enrollment.boxStaticPublic),
            rendezvousSecret: Data(enrollment.rendezvousSecret),
            pairingCode: Data(enrollment.pairingCode),
            lanHint: enrollment.lanHint.isEmpty ? nil : enrollment.lanHint,
            addedAtMs: at,
            lastSeenAtMs: at
        )
        sites.put(site)
        return site
    }
}
