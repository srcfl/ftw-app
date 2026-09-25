import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The sealed copy Sourceful holds, so a new phone is not a dead end.
///
/// "Sourceful holds a sealed copy it cannot open, with an opaque id and
/// nothing beside it." Sealed under a key derived from PRF output; the id is
/// an HKDF sibling of that key; a write is signed, a read is not, because a
/// fresh install has a passkey and nothing else. The wire is the web app's,
/// so either app reads what the other wrote.
///
/// Losing the service costs a QR scan. Nothing depends on it.
@MainActor
public final class Escrow {
    /// Every request body is exactly this long; the service refuses others.
    static let requestBytes = 1024

    public enum SaveOutcome: Equatable, Sendable {
        case saved, cleared, unsupported, unreachable, failed, conflict
    }

    public enum RemoveOutcome: Equatable, Sendable {
        case removed, nothingToRemove, declined, kept
    }

    public struct EscrowError: Error, Equatable, HelpfulError {
        public let code: String
        public let message: String
        public let help: String
    }

    /// One POST to one path. Injected by tests.
    public typealias Transport = @MainActor (_ body: Bytes) async throws -> (status: Int, body: Bytes)

    private let transport: Transport
    private let vault: Vault
    private let sites: SiteList

    public init(vault: Vault, sites: SiteList, transport: Transport? = nil) {
        self.vault = vault
        self.sites = sites
        self.transport = transport ?? Escrow.urlSessionTransport(Origin.escrowURL.appendingPathComponent("e"))
    }

    // MARK: Which homes

    /// The homes this household asked to be held, oldest first.
    public func escrowedHomes() -> [RecoveryBlob.Home] {
        sites.all()
            .filter { $0.escrow && $0.rendezvousSecret != nil }
            .sorted { $0.addedAtMs < $1.addedAtMs }
            .map { RecoveryBlob.Home(siteId: $0.siteId, label: $0.label, boxStaticKey: $0.boxStaticKey.byteArray, rendezvousSecret: $0.rendezvousSecret!.byteArray) }
    }

    public func mark(_ siteId: String, _ on: Bool) {
        sites.update(siteId) { $0.escrow = on }
    }

    // MARK: Writing

    /// Put the marked homes in the escrow, replacing what was there. Reports
    /// rather than throws: a device with no spare copy is the device everyone
    /// had yesterday.
    public func save(_ wrapping: WrappingKey, pending: RecoveryBlob.Home? = nil) async -> SaveOutcome {
        guard let keys = wrapping.escrow else { return .unsupported }
        do {
            var homes = escrowedHomes()
            if let pending {
                homes = homes.filter { $0.siteId != pending.siteId } + [pending]
            }
            if homes.isEmpty {
                return try await clear(keys) ? .cleared : .conflict
            }
            var scalar = try vault.exportDeviceSecret(wrapping)
            defer { wipe(&scalar) }
            // Twice at most. The version is bound into the seal, so losing a
            // race means sealing again under the new number.
            for _ in 0..<2 {
                let held = try await readHeld(keys.lookupID)
                let version = (held?.version ?? 0) + 1
                let sealed = try RecoveryBlob.seal(key: keys.sealKey, .init(deviceScalar: scalar, homes: homes), escrowVersion: version)
                if try await put(keys, version: version, blob: sealed) { return .saved }
            }
            return .conflict
        } catch is EscrowError {
            return .unreachable
        } catch {
            return .failed
        }
    }

    /// Take the copy away. Costs nothing at all when no home opted in.
    public func remove(_ passkeys: PasskeyAuthenticator?) async -> RemoveOutcome {
        if escrowedHomes().isEmpty { return .nothingToRemove }
        let wrapping: WrappingKey
        do {
            wrapping = try await vault.unlockWrappingKey(passkeys)
        } catch is PasskeyCancelled {
            return .declined
        } catch {
            return .kept
        }
        guard let keys = wrapping.escrow else { return .kept }
        do {
            return try await clear(keys) ? .removed : .kept
        } catch {
            return .kept
        }
    }

    /// Empty the copy rather than delete the row: a delete would restart the
    /// version at 1, and a kept old blob could then be written straight back.
    private func clear(_ keys: EscrowKeys) async throws -> Bool {
        for _ in 0..<2 {
            guard let held = try await readHeld(keys.lookupID) else { return true }
            if held.blob.isEmpty { return true }
            if try await put(keys, version: held.version + 1, blob: []) { return true }
        }
        return false
    }

    // MARK: Bringing a home back

    public struct Recovered: Identifiable, Sendable {
        public let siteId: String
        public let label: String
        public let fingerprint: String
        let deviceScalar: Bytes
        let wrapping: WrappingKey
        let everyHome: [RecoveryBlob.Home]
        public var id: String { siteId }
    }

    /// One ceremony yields the id and the key. An empty result is the
    /// ordinary answer for a passkey that never saved anything; a copy that is
    /// there and will not open throws, because that one means something
    /// replaced it.
    public func recover(_ passkeys: PasskeyAuthenticator?) async throws -> [Recovered] {
        guard let passkeys, passkeys.isAvailable else { return [] }
        let outcome = try await passkeys.assert(credentialIDs: [])
        guard let prf = outcome.prfOutput else {
            throw RecoveryBlob.BlobError(code: "E_BLOB_LOCKED", message: "no PRF output", help: "This passkey cannot unlock what was saved. Open your box's local dashboard and use Settings → FTW app → Show pairing code.")
        }
        let wrapping = PRF.wrappingKey(credentialID: outcome.credentialID, prfOutput: prf)
        guard let keys = wrapping.escrow else { return [] }
        guard let held = try await readHeld(keys.lookupID), !held.blob.isEmpty else { return [] }
        let contents = try RecoveryBlob.open(key: keys.sealKey, held.blob, escrowVersion: held.version)
        return contents.homes.map {
            Recovered(siteId: $0.siteId, label: $0.label, fingerprint: SiteList.fingerprint($0.boxStaticKey), deviceScalar: contents.deviceScalar, wrapping: wrapping, everyHome: contents.homes)
        }
    }

    /// Write a recovered home down. The device key is put back rather than
    /// minted, wrapped under the local key so connecting stays silent and
    /// under the passkey that just answered. Every home in the copy is
    /// written, because the next save rebuilds the copy from this disk.
    @discardableResult
    public func adopt(_ home: Recovered, nowMs: Double) throws -> String {
        let local = vault.localWrappingKey()
        try vault.restoreDeviceKey(local, scalar: home.deviceScalar)
        try vault.addCredential(current: local, next: home.wrapping)
        for each in home.everyHome {
            sites.put(StoredSite(
                siteId: each.siteId,
                label: each.label,
                boxStaticKey: Data(each.boxStaticKey),
                rendezvousSecret: Data(each.rendezvousSecret),
                pairingCode: nil,
                lanHint: nil,
                escrow: true,
                addedAtMs: nowMs,
                lastSeenAtMs: nowMs
            ))
        }
        return home.siteId
    }

    // MARK: The wire

    struct Held {
        var version: UInt32
        var blob: Bytes
    }

    private func readHeld(_ lookupID: String) async throws -> Held? {
        let response = try await request([("op", .string("get")), ("id", .string(lookupID))])
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw refused(response.status) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any],
              let version = (object["version"] as? NSNumber)?.uint32Value,
              let text = object["blob"] as? String,
              let blob = Data(base64Encoded: text)?.byteArray,
              blob.count == RecoveryBlob.maxBytes || blob.isEmpty else {
            throw refused(response.status)
        }
        return Held(version: version, blob: blob)
    }

    /// The bytes a write is signed over; the service's `writeMessage`.
    static func writeMessage(lookupID: String, version: UInt32, blob: Bytes) -> Bytes {
        Array("ftw-escrow:v1:\(lookupID):\(version):\(Primitives.sha256(blob).hex)".utf8)
    }

    /// True when it landed; false is a lost race and nothing else.
    private func put(_ keys: EscrowKeys, version: UInt32, blob: Bytes) async throws -> Bool {
        let signature = try keys.sign(Self.writeMessage(lookupID: keys.lookupID, version: version, blob: blob))
        let response = try await request([
            ("op", .string("put")),
            ("id", .string(keys.lookupID)),
            ("version", .number(Int(version))),
            ("blob", .string(Data(blob).base64EncodedString())),
            ("pub", .string(Base64url.encode(keys.writeKey))),
            ("sig", .string(Base64url.encode(signature))),
        ])
        if response.status == 200 { return true }
        if response.status == 409 { return false }
        throw refused(response.status)
    }

    enum Field {
        case string(String)
        case number(Int)
    }

    /// `body` as JSON with a `pad` member that makes the whole exactly
    /// `bytes` long, the way the web app pads it. The id never goes in a URL:
    /// a URL is what every layer writes down.
    static func padded(_ fields: [(String, Field)], to bytes: Int = requestBytes) -> Bytes {
        func render(_ pad: String) -> String {
            var parts = fields.map { key, value -> String in
                switch value {
                case .string(let s): return "\(jsonString(key)):\(jsonString(s))"
                case .number(let n): return "\(jsonString(key)):\(n)"
                }
            }
            parts.append("\"pad\":\(jsonString(pad))")
            return "{" + parts.joined(separator: ",") + "}"
        }
        let empty = render("")
        return Array(render(String(repeating: "A", count: max(0, bytes - empty.utf8.count))).utf8)
    }

    private func request(_ fields: [(String, Field)]) async throws -> (status: Int, body: Bytes) {
        do {
            return try await transport(Self.padded(fields))
        } catch {
            throw EscrowError(code: "E_ESCROW_UNREACHABLE", message: "the escrow could not be reached", help: "The saved copy could not be reached. Your home works either way — try again when you are back online.")
        }
    }

    private func refused(_ status: Int) -> EscrowError {
        EscrowError(code: "E_ESCROW_REFUSED", message: "the escrow answered \(status)", help: "The saved copy could not be read. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR instead.")
    }

    /// No cookies, no cache, nothing an origin could be recognised by.
    static func urlSessionTransport(_ url: URL) -> Transport {
        { body in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = Data(body)
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data.byteArray)
        }
    }
}

/// A JSON string literal. Only what JSON requires is escaped, which is what
/// JavaScript's JSON.stringify does for these ASCII values.
func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
