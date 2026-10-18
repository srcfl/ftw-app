import FTWDemo
import Foundation
import Testing

@testable import FTWKit

@MainActor @Suite struct InvitationTests {
    struct Vector: Decodable {
        let home, boxHex, secretHex, deviceId, hashHex, signedHex, code: String
    }
    @Test func codeHashAndApprovalMatchCore() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "invitation-vectors", withExtension: "json", subdirectory: "Resources"))
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let secret = Bytes(hex: v.secretHex)
        let box = Bytes(hex: v.boxHex)
        #expect(InvitationWire.hash(home: v.home, secret: secret) == Bytes(hex: v.hashHex))
        #expect(InvitationWire.code(home: v.home, box: box, secret: secret) == v.code)
        let m = InvitationCreate(
            id: Base64url.encode(Bytes(repeating: 0x55, count: 16)), home: v.home, label: "Hannes",
            hash: Bytes(hex: v.hashHex),
            grant: Grant(
                scopes: ["ftw.diag.run", "ftw.live.read"], ops: [], caps: Caps(), lengthMs: 86_400_000),
            claimUntilMs: 1_792_000_060_000, expiresAtMs: 1_792_086_400_000, atMs: 1_792_000_000_000)
        #expect(
            try m.signedBytes(SignedFor(boxKey: box, deviceID: v.deviceId)) == Bytes(hex: v.signedHex))
    }
}

extension AccessFlowTests {
    @Test func invitationLengthsFollowTheBoxBeforeBiometry() async throws {
        let day: Int64 = 86_400_000
        for limit in [Int64?.none, 2 * day, 365 * day] {
            let w = await world(seed: false)
            w.box.access.longestMs = limit.map { [Contract.roleAgent: $0] }
            await w.during { await w.access.refresh() }
            let expected: [Int64] = limit == nil ? [day, 7 * day, 30 * day]
                : limit == 2 * day ? [day] : [day, 7 * day, 30 * day, 90 * day, 365 * day]
            #expect(w.access.invitationLengths == expected)
            let unlocks = w.keyring.unlocks
            let draft = InvitationDraft()
            let invalid = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: (limit ?? 30 * day) + day)
            let row = await w.during {
                await w.access.createInvitation(draft, home: "abcdefghijklmnopqrstuvwx23", label: "Too long", grant: invalid, claimSeconds: 600)
            }
            #expect(row == nil && draft.request == nil)
            #expect(w.keyring.unlocks == unlocks)
            let valid = Grant(scopes: invalid.scopes, ops: [], caps: Caps(), lengthMs: try #require(expected.last))
            let accepted = await w.during {
                await w.access.createInvitation(draft, home: "abcdefghijklmnopqrstuvwx23", label: "Fits", grant: valid, claimSeconds: 600)
            }
            #expect(accepted?.state == "pending", "\(w.access.help ?? "")")
        }
    }

    @Test(arguments: ["cap", "claimUntilMs"])
    func definiteInvitationRefusalUnlocksTheFormForANewApproval(reason: String) async throws {
        let w = await world(seed: false)
        let home = "abcdefghijklmnopqrstuvwx23"
        let day: Int64 = 86_400_000
        let valid = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: day)
        _ = await w.during { await w.access.createInvitation(InvitationDraft(), home: home, label: "Register", grant: valid, claimSeconds: 600) }
        let draft = InvitationDraft()
        let tooLong = Grant(scopes: valid.scopes, ops: [], caps: Caps(), lengthMs: 365 * day)
        let at = Int64(w.scheduler.nowMs)
        var old = InvitationCreate(id: draft.id, home: home, label: "Old request", hash: InvitationWire.hash(home: home, secret: draft.secret),
                                   grant: tooLong, claimUntilMs: at + 600_000, expiresAtMs: at + tooLong.lengthMs, atMs: at)
        if reason == "claimUntilMs" {
            old.atMs = at - 601_000
            old.claimUntilMs = at - 1_000
            old.expiresAtMs = at + day
        }
        old.sig = try #require(try w.keyring.existing()).sign(try old.signedBytes(AccessModel.demoFor))
        draft.request = old
        w.box.access.longestMs = nil
        let refused = await w.during { await w.access.createInvitation(draft, home: home, label: "Ignored", grant: tooLong, claimSeconds: 600) }
        #expect(refused == nil && draft.receipt == nil && draft.request == nil)
        let unlocks = w.keyring.unlocks
        let accepted = await w.during { await w.access.createInvitation(draft, home: home, label: "Shorter", grant: valid, claimSeconds: 600) }
        #expect(accepted?.state == "pending")
        #expect(draft.request?.label == "Shorter" && draft.request != old)
        #expect(w.keyring.unlocks == unlocks + 1)
    }

    @Test func invitationIsSignedAndAnExactRetryKeepsItsReceipt() async throws {
        let w = await world(seed: false)
        let draft = InvitationDraft()
        let grant = Grant(
            scopes: ["ftw.diag.run", "ftw.live.read"], ops: [], caps: Caps(), lengthMs: 7 * 86_400_000)
        let home = "abcdefghijklmnopqrstuvwx23"
        let first = await w.during {
            await w.access.createInvitation(
                draft, home: home, label: "Hannes", grant: grant, claimSeconds: 3600)
        }
        #expect(first?.state == "pending")
        #expect(draft.code != nil)
        let request = try #require(draft.request)
        #expect(
            Approval.verify(
                pub: try #require(w.box.access.keys[AccessModel.demoFor.deviceID]),
                message: try request.signedBytes(AccessModel.demoFor), sig: request.sig))
        _ = await w.during {
            await w.access.createInvitation(
                draft, home: home, label: "Changed after send", grant: grant, claimSeconds: 600)
        }
        #expect(draft.request == request)
        #expect(draft.receipt?.label == "Hannes")
        #expect(w.access.invitations.count == 1)
        let receipt = try #require(draft.receipt)
        let ended = await w.during { await w.access.cancelInvitation(receipt) }
        #expect(ended?.state == "cancelled")
    }

    @Test func lostInvitationReplyRecoversFromTheBoxWithoutChangingSignedBytes() async throws {
        let w = await world(seed: false)
        let grant = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: 86_400_000)
        let home = "abcdefghijklmnopqrstuvwx23"
        _ = await w.during {
            await w.access.createInvitation(
                InvitationDraft(), home: home, label: "First", grant: grant, claimSeconds: 3600)
        }
        let draft = InvitationDraft()
        w.box.access.loseNextInvitationAnswer = true
        let task = Task {
            await w.access.createInvitation(
                draft, home: home, label: "Lost reply", grant: grant, claimSeconds: 3600)
        }
        await w.run(12_000)
        _ = await task.value
        let request = try #require(draft.request)
        #expect(draft.receipt?.state == "pending")
        #expect(draft.code != nil)
        _ = await w.during {
            await w.access.createInvitation(
                draft, home: home, label: "Ignored", grant: grant, claimSeconds: 600)
        }
        #expect(draft.request == request)
        #expect(w.access.invitations.count == 2)
    }

    @Test func invitationRecoversAReplacementKeyWithoutChangingItsFields() async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let old = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        w.box.access.loseNextAnswer = true
        let replacing = Task { await w.access.replaceKey() }
        await w.run(10_000)
        #expect(await replacing.value == false)
        let taken = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        #expect(taken != old)
        let draft = InvitationDraft()
        let grant = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: 86_400_000)
        let row = await w.during {
            await w.access.createInvitation(
                draft, home: "abcdefghijklmnopqrstuvwx23", label: "After replacement", grant: grant, claimSeconds: 3600)
        }
        #expect(row?.state == "pending", "\(w.access.help ?? "")")
        let request = try #require(draft.request)
        #expect(Approval.verify(pub: taken, message: try request.signedBytes(AccessModel.demoFor), sig: request.sig))
        #expect(try w.keyring.existing()?.publicKey == taken)
        #expect(try w.keyring.pending() == nil)
        #expect(w.keyring.ends == w.keyring.unlocks)
    }

    @Test(arguments: [300_000.0, 900_000.0, -900_000.0])
    func invitationUsesTheBoxTimeBeforeItCachesMaximumLengths(phoneClockOffMs: Double) async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let access = AccessModel(
            site: w.site, signedFor: AccessModel.demoFor, keyring: w.keyring, wallMs: { w.scheduler.nowMs + phoneClockOffMs },
            invitationLookup: SimulatedAccess.lookup)
        let draft = InvitationDraft()
        let grant = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: 365 * 86_400_000)
        let row = await w.during {
            await access.createInvitation(draft, home: "abcdefghijklmnopqrstuvwx23", label: "Clock", grant: grant, claimSeconds: 86400)
        }
        #expect(row?.state == "pending", "\(access.help ?? "")")
        let request = try #require(draft.request)
        #expect(abs(request.atMs - Int64(w.scheduler.nowMs)) < 3000)
        #expect(request.claimUntilMs <= Int64(w.scheduler.nowMs) + 86_400_000)
        #expect(request.expiresAtMs <= Int64(w.scheduler.nowMs) + 365 * 86_400_000)
    }

    @Test func lostShortCodeReplyRetriesTheSameProofWithoutAnotherApproval() async throws {
        let w = await world(seed: false)
        let recorder = InvitationPublicationRecorder()
        let lookup = OfferLookup(base: URL(string: "https://closed-test.invalid")!) { request in
            try await recorder.reply(request)
        }
        let access = AccessModel(
            site: w.site, signedFor: AccessModel.demoFor, keyring: w.keyring, wallMs: { w.scheduler.nowMs }, invitationLookup: lookup)
        let draft = InvitationDraft()
        let grant = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(), lengthMs: 86_400_000)
        _ = await w.during {
            await access.createInvitation(draft, home: "abcdefghijklmnopqrstuvwx23", label: "Hannes", grant: grant, claimSeconds: 600)
        }
        #expect(draft.receipt?.state == "pending")
        #expect(draft.code == nil)
        let request = try #require(draft.request)
        let unlocks = w.keyring.unlocks
        await access.publishInvitation(draft)
        #expect(draft.code == "K7M-4PX")
        #expect(draft.request == request)
        #expect(w.keyring.unlocks == unlocks)
        #expect(access.invitations.count == 1)
        let bodies = await recorder.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
    }
}

private actor InvitationPublicationRecorder {
    private(set) var bodies: [Data] = []
    func reply(_ request: URLRequest) throws -> (Data, Int) {
        bodies.append(request.httpBody ?? Data())
        if bodies.count == 1 { throw URLError(.networkConnectionLost) }
        return (
            try JSONSerialization.data(withJSONObject: [
                "code": "K7M-4PX", "expiresAtMs": Int64(Date().timeIntervalSince1970 * 1000) + 600_000,
            ]), 200
        )
    }
}
