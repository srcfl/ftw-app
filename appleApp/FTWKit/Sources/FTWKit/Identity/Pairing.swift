import Foundation

/// From a scanned code to a paired home, in the order that keeps it to two
/// taps and fails before the passkey prompt whenever it can:
///
///   1. Parse the QR. A bad code fails before anyone is asked for Face ID.
///   2. Ask for the passkey, once.
///   3. Unwrap or create the device key, and make the local copy.
///   4. Store the home, pinned to the box key from the QR.
///
/// Only then does anything touch the network, and the spare copy is written
/// in the background without delaying the house.
@MainActor
public final class Pairing {
    private let vault: Vault
    private let sites: SiteList
    private let escrow: Escrow
    private let passkeys: PasskeyAuthenticator?
    private let now: () -> Double

    public init(vault: Vault, sites: SiteList, escrow: Escrow, passkeys: PasskeyAuthenticator?, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.vault = vault
        self.sites = sites
        self.escrow = escrow
        self.passkeys = passkeys
        self.now = now
    }

    public struct Paired: Sendable {
        public let site: StoredSite
        /// The background seal of the spare copy, for tests to await.
        public let sealed: Task<Escrow.SaveOutcome?, Never>
    }

    /// Throws `EnrollmentError` with a sentence, or `PasskeyCancelled`.
    public func pair(scanned: String, holdCopy: Bool = true) async throws -> Paired {
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
            escrow: sites.get(siteId)?.escrow ?? false,
            addedAtMs: at,
            lastSeenAtMs: at
        )
        sites.put(site)

        // Hold a sealed copy from the first device, by default and in the
        // background. The mark follows the write, so the Box screen never
        // says a copy is held when it is not.
        let escrow = self.escrow
        let sealed = Task { @MainActor () -> Escrow.SaveOutcome? in
            guard holdCopy, wrapping.escrow != nil else { return nil }
            let outcome = await escrow.save(wrapping, pending: RecoveryBlob.Home(
                siteId: site.siteId,
                label: site.label,
                boxStaticKey: site.boxStaticKey.byteArray,
                rendezvousSecret: site.rendezvousSecret?.byteArray ?? []
            ))
            escrow.mark(site.siteId, outcome == .saved)
            return outcome
        }
        return Paired(site: site, sealed: sealed)
    }

    /// Arm the next handshake with a code read off the box's screen. For a
    /// phone that has been here before: a box code carries no box key and no
    /// rendezvous secret, so a phone with no row for this home scans instead.
    /// The decode happens before the disk is touched, so a typo costs nothing.
    public func redeemBoxCode(siteId: String, typed: String) throws {
        let code = try BoxCode.decode(typed)
        guard sites.get(siteId) != nil else {
            throw BoxCode.BoxCodeError(message: "no site \(siteId)", help: "This phone has no record of that home. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR instead.")
        }
        sites.update(siteId) { $0.pairingCode = Data(code) }
    }
}
