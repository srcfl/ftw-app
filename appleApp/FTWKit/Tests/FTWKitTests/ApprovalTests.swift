import CryptoKit
import Foundation
import Testing
@testable import FTWKit

/// srcfl/ftw `go/protocol/testdata/approval-vectors.json`, copied byte for
/// byte. The box made these with the code it checks approvals with, so
/// building the same bytes here is what lets a phone's signature verify at
/// a box.
struct ApprovalVectors: Decodable {
    struct Case: Decodable {
        let what: String
        let bodyHex: String
        let contextHex: String?
        let signedHex: String
        let sha256Hex: String
        let sigHex: String
    }

    struct Offer: Decodable {
        let kid: String
        let pubHex: String
        let nowMs: Int64
        let signedOfferHex: String
        let oHex: String
        let signedBytesHex: String
    }

    let pubHex: String
    let boxKeyHex: String
    let deviceId: String
    let cases: [Case]
    let offer: Offer

    static func load() throws -> ApprovalVectors {
        guard let url = Bundle.module.url(forResource: "approval-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(ApprovalVectors.self, from: Data(contentsOf: url))
    }

    var signedFor: SignedFor { SignedFor(boxKey: Bytes(hex: boxKeyHex), deviceID: deviceId) }
}

@MainActor
@Suite struct ApprovalTests {
    let v: ApprovalVectors

    init() throws {
        v = try ApprovalVectors.load()
    }

    /// The bytes this phone would sign for each body the box signed, the
    /// box's own context added: equal to the box's, byte for byte.
    @Test func theSignedBytesAreTheBoxs() throws {
        #expect(v.cases.count == 5)
        for c in v.cases {
            let body = try decodeCBOR(Bytes(hex: c.bodyHex))
            let built = try signedBytes(c, body)
            #expect(built.hex == c.signedHex, "\(c.what)")
            #expect(Primitives.sha256(built).hex == c.sha256Hex, "\(c.what)")
        }
    }

    /// The box's signatures verify here over those bytes, and nothing else
    /// does.
    @Test func theBoxsSignaturesVerify() throws {
        let pub = Bytes(hex: v.pubHex)
        for c in v.cases {
            let signed = Bytes(hex: c.signedHex)
            var sig = Bytes(hex: c.sigHex)
            #expect(Approval.verify(pub: pub, message: signed, sig: sig), "\(c.what)")
            sig[10] ^= 1
            #expect(!Approval.verify(pub: pub, message: signed, sig: sig), "\(c.what)")
            #expect(!Approval.verify(pub: pub, message: signed + [0], sig: Bytes(hex: c.sigHex)), "\(c.what)")
        }
    }

    /// A body this app sends is the box's bytes when it says the same.
    @Test func theBodiesAreTheBoxs() throws {
        let keySet = try #require(v.cases.first { $0.what == Approval.keySet })
        let ks = try decodeCBOR(Bytes(hex: keySet.bodyHex))
        let sent = CBOR.map([("pub", ks["pub"]!), ("atMs", ks["atMs"]!), ("sig", ks["sig"]!)]).deterministic
        #expect(encodeCBOR(sent).hex == keySet.bodyHex)

        let addCase = try #require(v.cases.first { $0.what == Approval.add })
        let b = try decodeCBOR(Bytes(hex: addCase.bodyHex))
        var add = try agentAdd(b)
        add.sig = b["sig"]!.byteString!
        #expect(encodeCBOR(add.cbor).hex == addCase.bodyHex)
    }

    /// A signature made here verifies under the same rules: r ‖ s over
    /// SHA-256 of the bytes, as CryptoKit hashes them itself.
    @Test func aSignatureMadeHereVerifies() throws {
        let signer = SoftwareSigner()
        let msg = Approval.keySetBytes(v.signedFor, atMs: 1_792_000_000_000, pub: signer.publicKey)
        let sig = try signer.sign(msg)
        #expect(sig.count == Approval.sigBytes)
        #expect(signer.publicKey.count == Approval.pubBytes && signer.publicKey[0] == 4)
        #expect(Approval.verify(pub: signer.publicKey, message: msg, sig: sig))
        // Bound to the box and the phone.
        var other = v.signedFor
        other.deviceID = "otherPh1"
        #expect(!Approval.verify(pub: signer.publicKey, message: Approval.keySetBytes(other, atMs: 1_792_000_000_000, pub: signer.publicKey), sig: sig))
    }

    /// The box refuses a list that is not sorted or repeats; so does the
    /// phone, before Face ID.
    @Test func anUnsortedListIsNoApproval() {
        let add = AgentAdd(key: Bytes(repeating: 1, count: 32), role: "agent", scopes: ["ftw.plan.read", "ftw.live.read"], ops: [],
                           caps: Caps(), expiresAtMs: 2, principal: Principal(), atMs: 1)
        #expect(throws: Approval.Unsorted.self) { try Approval.addBytes(v.signedFor, add) }
        #expect(!Approval.isSortedUnique(["a", "a"]))
        #expect(Approval.isSortedUnique(["ftw.live.read", "ftw.plan.read"]))
        #expect(Approval.sorted(["b", "a", "b"]) == ["a", "b"])
    }

    /// Deterministic CBOR orders a map's keys by their encoding: shorter
    /// text first, then bytewise, at every depth.
    @Test func mapsAreInTheBoxsOrder() {
        let m = CBOR.map([("args", .map([("zz", .int(1)), ("a", .int(2))])), ("op", .text("x")), ("why", .text(""))])
        let out = m.deterministic.entries!.map { $0.key.string! }
        #expect(out == ["op", "why", "args"])
        #expect(m.deterministic["args"]!.entries!.map { $0.key.string! } == ["a", "zz"])
        // Floats in their shortest exact form, as the box writes them.
        #expect(encodeDeterministic(.double(0.5)).hex == "f93800")
        #expect(encodeDeterministic(.double(0.1)).hex == "fb3fb999999999999a")
    }

    // MARK: Building the bytes from a body, as the phone does

    func signedBytes(_ c: ApprovalVectors.Case, _ b: CBOR) throws -> Bytes {
        let f = v.signedFor
        let atMs = b["atMs"]!.int64!
        switch c.what {
        case Approval.keySet:
            return Approval.keySetBytes(f, atMs: atMs, pub: b["pub"]!.byteString!)
        case Approval.add:
            return try Approval.addBytes(f, try agentAdd(b))
        case Approval.widen:
            let m = AgentWiden(id: b["id"]!.string!, epoch: UInt64(b["epoch"]!.int64!), scopes: b["scopes"]?.stringArray ?? [],
                               ops: b["ops"]?.stringArray ?? [], caps: Caps(b["caps"]), expiresAtMs: b["expiresAtMs"]!.int64!, atMs: atMs)
            return try Approval.widenBytes(f, m, key: Bytes(hex: c.contextHex!))
        case Approval.confirm:
            let req = try #require(AgentRequest(try decodeCBOR(Bytes(hex: c.contextHex!))))
            return Approval.confirmBytes(f, reqId: b["reqId"]!.string!, atMs: atMs, request: req)
        default:
            Issue.record("unknown case \(c.what)")
            return []
        }
    }

    func agentAdd(_ b: CBOR) throws -> AgentAdd {
        AgentAdd(key: b["key"]!.byteString!, role: b["role"]!.string!, scopes: b["scopes"]?.stringArray ?? [],
                 ops: b["ops"]?.stringArray ?? [], caps: Caps(b["caps"]), expiresAtMs: b["expiresAtMs"]!.int64!,
                 principal: Principal(b["principal"]), atMs: b["atMs"]!.int64!)
    }
}
