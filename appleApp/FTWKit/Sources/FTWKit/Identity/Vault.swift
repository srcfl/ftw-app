import Foundation

/// The device key and the copies that unlock it.
///
///     device key    X25519 static for Noise, stored AES-GCM wrapped once per
///                   credential.
///     wrapping key  from passkey PRF, at enrollment and before privileged
///                   acts. Never stored.
///     local key     random, in the Keychain, no prompt in front of it. It is
///                   what lets reading the house cost no Face ID.
///
/// The local copy is the cache key's claim and no more: it resists an
/// offline read of the disk, not someone holding the unlocked phone, who can
/// simply open the app and look. PRF still guards enrollment and the writes
/// that need a step-up.
///
/// The sealed plaintext is PKCS#8, the same bytes the web app seals, so a
/// record either one writes opens in the other given the same passkey.
@MainActor
public final class Vault {
    public static let localCredentialID = "local"
    /// The box names a phone by this many characters of its key.
    public static let boxDeviceIDChars = 8

    static let vaultKey = "device-key"
    static let localWrapKey = "local-wrap-key"
    static let userHandleKey = "user-handle"

    /// DER header of a PKCS#8 X25519 private key; the scalar is the last 32.
    nonisolated static let pkcs8Prefix: Bytes = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]

    public struct VaultError: Error, Equatable, HelpfulError {
        public let code: String
        public let message: String
        public let help: String
    }

    struct Copy: Codable, Equatable {
        var credentialId: String
        var source: WrappingSource
        var iv: Data
        var ct: Data
    }

    struct Record: Codable, Equatable {
        var publicKey: Data
        var copies: [Copy]
    }

    private let store: SecureStore

    public init(store: SecureStore) {
        self.store = store
    }

    // MARK: Reads that never prompt

    public var isEnrolled: Bool { record != nil }

    public var devicePublic: Bytes? { record.map { $0.publicKey.byteArray } }

    /// The name this phone answers to on the box's list of paired phones,
    /// worked out locally so it is here exactly when the box is not.
    public var deviceIDOnBox: String? {
        devicePublic.map { String(Base64url.encode($0).prefix(Self.boxDeviceIDChars)) }
    }

    public var credentialIDs: [String] { record?.copies.map(\.credentialId) ?? [] }

    /// Only the copies a passkey stands behind. The local copy is not one.
    public var passkeyCredentialIDs: [String] {
        record?.copies.filter { $0.source == .prf }.map(\.credentialId) ?? []
    }

    // MARK: The device key

    /// The device key, created on first use. It is this phone's identity, so
    /// pairing a second box reuses it rather than orphaning the first.
    public func deviceKey(_ wrapping: WrappingKey) throws -> Primitives.KeyPair {
        guard let record else { return try create(wrapping) }
        guard let copy = record.copies.first(where: { $0.credentialId == wrapping.credentialID }) else {
            throw noCopy(wrapping.credentialID)
        }
        var pkcs8 = try unseal(wrapping.key, copy)
        defer { wipe(&pkcs8) }
        return try Primitives.keyPair(fromSecret: Array(pkcs8.suffix(32)))
    }

    /// The raw scalar, for the one caller allowed to copy it off this device:
    /// the sealed recovery copy. The caller wipes what it gets.
    public func exportDeviceSecret(_ wrapping: WrappingKey) throws -> Bytes {
        guard let record else { throw emptyVault() }
        guard let copy = record.copies.first(where: { $0.credentialId == wrapping.credentialID }) else {
            throw noCopy(wrapping.credentialID)
        }
        var pkcs8 = try unseal(wrapping.key, copy)
        defer { wipe(&pkcs8) }
        return Array(pkcs8.suffix(32))
    }

    /// Put back a device key from a sealed copy: the Noise static the box
    /// already trusts, which is why no pairing code is needed. Refuses to sit
    /// on top of a different identity.
    @discardableResult
    public func restoreDeviceKey(_ wrapping: WrappingKey, scalar: Bytes) throws -> Primitives.KeyPair {
        let pair = try Primitives.keyPair(fromSecret: scalar)
        let existing = record
        if let existing, existing.publicKey.byteArray != pair.publicKey {
            throw VaultError(code: "E_VAULT_OTHER_KEY", message: "a different device key is already stored", help: "This phone is already set up for a home. Sign out of it first.")
        }
        var pkcs8 = Self.pkcs8Prefix + scalar
        defer { wipe(&pkcs8) }
        var copies = (existing?.copies ?? []).filter { $0.credentialId != wrapping.credentialID }
        copies.append(try seal(wrapping, pkcs8))
        write(Record(publicKey: Data(pair.publicKey), copies: copies))
        return pair
    }

    /// Wrap the device key under another credential. `current` must already
    /// open it: prove you can unlock before you widen access.
    public func addCredential(current: WrappingKey, next: WrappingKey) throws {
        guard let record else { throw emptyVault() }
        guard let copy = record.copies.first(where: { $0.credentialId == current.credentialID }) else {
            throw noCopy(current.credentialID)
        }
        var pkcs8 = try unseal(current.key, copy)
        defer { wipe(&pkcs8) }
        var copies = record.copies.filter { $0.credentialId != next.credentialID }
        copies.append(try seal(next, pkcs8))
        write(Record(publicKey: record.publicKey, copies: copies))
    }

    /// Refuses the last copy, which would strand the device key for good.
    public func removeCredential(_ credentialID: String) throws {
        guard let record else { throw emptyVault() }
        let copies = record.copies.filter { $0.credentialId != credentialID }
        if copies.count == record.copies.count { return }
        if copies.isEmpty {
            throw VaultError(code: "E_VAULT_LAST_COPY", message: "refusing to remove the only wrapped copy", help: "That is the only passkey that can unlock this device. Add another one first.")
        }
        write(Record(publicKey: record.publicKey, copies: copies))
    }

    /// Forget this device's identity. Callers leaving a home clear the sites
    /// and the cached readings as well; see `AppModel.leave`.
    public func reset() {
        store.remove(Self.vaultKey)
        store.remove(Self.localWrapKey)
        store.remove(Self.userHandleKey)
    }

    // MARK: Wrapping keys

    /// The local key: random, in the Keychain, no ceremony in front of it.
    public func localWrappingKey() -> WrappingKey {
        if let existing = store.get(Self.localWrapKey), existing.count == 32 {
            return WrappingKey(credentialID: Self.localCredentialID, source: .local, key: existing, escrow: nil)
        }
        let key = randomBytes(32)
        store.put(Self.localWrapKey, key)
        return WrappingKey(credentialID: Self.localCredentialID, source: .local, key: key, escrow: nil)
    }

    /// The key for connecting, without a prompt, or nil when only passkey
    /// copies exist. Reading your own house is not a privilege.
    public func silentWrappingKey() throws -> WrappingKey? {
        guard let record else { throw emptyVault() }
        return record.copies.contains { $0.credentialId == Self.localCredentialID } ? localWrappingKey() : nil
    }

    /// Add the local copy, so the next start never prompts.
    public func ensureLocalCopy(_ current: WrappingKey) throws {
        guard let record else { throw emptyVault() }
        if record.copies.contains(where: { $0.credentialId == Self.localCredentialID }) { return }
        try addCredential(current: current, next: localWrappingKey())
    }

    /// A key for a device enrolling now: one prompt, no questions. Where PRF
    /// is missing this still returns a key, the local one, and `source` says
    /// so. A decline is rethrown; any other platform failure falls back.
    public func enrollWrappingKey(_ passkeys: PasskeyAuthenticator?, label: String = Origin.rpName) async throws -> WrappingKey {
        guard let passkeys, passkeys.isAvailable else { return localWrappingKey() }
        do {
            let outcome = try await passkeys.register(label: label, userHandle: userHandle(), excludeCredentialIDs: credentialIDs)
            if let prf = outcome.prfOutput {
                return PRF.wrappingKey(credentialID: outcome.credentialID, prfOutput: prf)
            }
            // Some platforms register the passkey and only evaluate PRF on an
            // assertion. One more prompt now, while the person is looking,
            // beats a vault nothing can open later.
            guard outcome.prfEnabled else { return localWrappingKey() }
            let asserted = try await passkeys.assert(credentialIDs: [outcome.credentialID])
            if let prf = asserted.prfOutput {
                return PRF.wrappingKey(credentialID: asserted.credentialID, prfOutput: prf)
            }
            return localWrappingKey()
        } catch is PasskeyCancelled {
            throw PasskeyCancelled()
        } catch {
            return localWrappingKey()
        }
    }

    /// The key for a device already enrolled: one prompt, or the local copy
    /// when no passkey can answer.
    public func unlockWrappingKey(_ passkeys: PasskeyAuthenticator?) async throws -> WrappingKey {
        guard let record else { throw emptyVault() }
        let ids = passkeyCredentialIDs
        if !ids.isEmpty, let passkeys, passkeys.isAvailable {
            do {
                let outcome = try await passkeys.assert(credentialIDs: ids)
                if let prf = outcome.prfOutput {
                    return PRF.wrappingKey(credentialID: outcome.credentialID, prfOutput: prf)
                }
            } catch is PasskeyCancelled {
                // A decline stays a decline. "Set this device up again" would
                // tell someone who tapped cancel to throw away a working phone.
                throw PasskeyCancelled()
            } catch {}
        }
        if record.copies.contains(where: { $0.credentialId == Self.localCredentialID }) {
            return localWrappingKey()
        }
        throw locked()
    }

    // MARK: Private

    private var record: Record? {
        store.getJSON(Record.self, Self.vaultKey)
    }

    private func write(_ record: Record) {
        store.putJSON(Self.vaultKey, record)
    }

    func userHandle() -> Bytes {
        if let existing = store.get(Self.userHandleKey) { return existing }
        // Stable per install, so a second passkey replaces the first in the
        // platform's list instead of stacking up identical entries.
        let handle = randomBytes(16)
        store.put(Self.userHandleKey, handle)
        return handle
    }

    private func create(_ wrapping: WrappingKey) throws -> Primitives.KeyPair {
        let pair = Primitives.generateKeyPair()
        var pkcs8 = Self.pkcs8Prefix + pair.secretKey
        defer { wipe(&pkcs8) }
        write(Record(publicKey: Data(pair.publicKey), copies: [try seal(wrapping, pkcs8)]))
        return pair
    }

    private func seal(_ wrapping: WrappingKey, _ plain: Bytes) throws -> Copy {
        let iv = randomBytes(12)
        let ct = try Primitives.aesGCMSeal(key: wrapping.key, nonce: iv, plaintext: plain)
        return Copy(credentialId: wrapping.credentialID, source: wrapping.source, iv: Data(iv), ct: Data(ct))
    }

    private func unseal(_ key: Bytes, _ copy: Copy) throws -> Bytes {
        do {
            return try Primitives.aesGCMOpen(key: key, nonce: copy.iv.byteArray, ciphertext: copy.ct.byteArray)
        } catch {
            throw locked()
        }
    }

    private func locked() -> VaultError {
        VaultError(code: "E_VAULT_LOCKED", message: "no wrapping key opens the stored copy", help: "This device can no longer unlock its key. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR.")
    }

    private func noCopy(_ credentialID: String) -> VaultError {
        VaultError(code: "E_VAULT_NO_COPY", message: "no wrapped copy for credential \(credentialID)", help: "This passkey has not been given access yet. Unlock with the one you set up first.")
    }

    private func emptyVault() -> VaultError {
        VaultError(code: "E_VAULT_EMPTY", message: "no device key has been created", help: "Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan the QR.")
    }
}

/// Proving, right now, that the person holding the phone is its owner.
///
/// The box cannot verify a ceremony happened; `stepUp: true` is this app's
/// word. What it stops is a phone left unlocked on a table being used to
/// reconfigure a house, because this app will not say `true` without the
/// ceremony below running. It never falls back to the local key.
public enum StepUpOutcome: Equatable, Sendable {
    case done
    case declined
    case unavailable

    public var help: String? {
        switch self {
        case .done: return nil
        case .declined: return "That needs your face or fingerprint. Try again when you are ready."
        case .unavailable: return "This phone cannot confirm it is yours. Changes have to be made on your box."
        }
    }
}

extension Vault {
    public func stepUp(_ passkeys: PasskeyAuthenticator?) async -> StepUpOutcome {
        guard let passkeys, passkeys.isAvailable else { return .unavailable }
        let ids = passkeyCredentialIDs
        if ids.isEmpty { return .unavailable }
        do {
            // The ceremony is what is asked for, not its PRF output: reaching
            // the next line without throwing is what says it ran.
            _ = try await passkeys.assert(credentialIDs: ids)
            return .done
        } catch is PasskeyCancelled {
            return .declined
        } catch {
            return .unavailable
        }
    }
}
