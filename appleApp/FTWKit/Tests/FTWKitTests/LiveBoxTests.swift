import Foundation
import Testing
@testable import FTWKit

/// Against a real FTW box, through FTW Cloud.
///
/// Off unless FTW_LIVE_URL holds a pairing URL the box just minted:
///
///     curl -s -X POST localhost:8080/api/app-link/pairing -d '{"role":"owner"}'
///     FTW_LIVE_URL='https://app.ftw.energy/p#v3...' swift test --filter LiveBox
///
/// The passkey ceremony cannot run here, so the device key is wrapped under
/// the local key alone. Everything after that is the shipped path: the real
/// socket, the Cloud tunnel, Noise IK with the pairing code in message 1,
/// the session, and the box's own API over it.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_URL"] != nil), .serialized)
struct LiveBoxTests {
    @Test func pairsStreamsAndCallsTheBoxThroughCloud() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["FTW_LIVE_URL"])
        let enrollment = try Enrollment.parse(scanned: url)
        let vault = Vault(store: MemoryStore())
        let device = try vault.deviceKey(vault.localWrappingKey())

        let scheduler = LiveScheduler()
        let home = try #require(enrollment.home)
        let cloud = CloudCarrier(endpoint: try #require(CloudEndpoint.current), home: home, deviceKey: device, looking: true,
                                 pair: CloudWire.pairingHash(home: home, code: enrollment.pairingCode), scheduler: scheduler, makeSocket: URLSessionWebSocket.factory())
        cloud.start()
        let tunnel = TunnelCarrier(cloud: cloud, scheduler: scheduler)
        let noise = NoiseCarrier(
            inner: tunnel,
            staticKey: device,
            remoteStatic: enrollment.boxStaticPublic,
            prologue: NoiseCarrier.prologue(boxStaticKey: enrollment.boxStaticPublic),
            handshakePayload: enrollment.pairingCode,
            scheduler: scheduler
        )
        let session = Session(build: "swift-live-test", ua: "test", scheduler: scheduler)
        session.connect(noise)
        defer { session.close() }

        let started = Date()
        while session.state.phase != .streaming, Date().timeIntervalSince(started) < 40 {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("live: phase \(session.state.phase) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, role \(session.state.role), caps \(session.state.caps.sorted())")
        #expect(session.state.phase == .streaming)
        #expect(session.state.heardFromBox)
        #expect(session.state.fields[Contract.FID.gridW] != nil)
        print("live: fields \(session.state.fields.sorted { $0.key < $1.key })")

        // A second of telemetry, then the box's own API over the session.
        let uptime = session.state.uptimeMs
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(session.state.uptimeMs > uptime)

        let status = try await session.api(APIRequest(method: .get, path: "/api/status"))
        #expect(status.status == 200)
        let json = try JSON(parsing: status.body)
        print("live: /api/status grid_w \(json["grid_w"]?.number ?? .nan), \(status.body.count) bytes")
        #expect(json["grid_w"]?.number != nil)

        let now = Date().timeIntervalSince1970 * 1000
        let prices = try await session.prices(fromMs: now, toMs: now + 86_400_000)
        print("live: prices \(prices.zone) \(prices.currency), \(prices.slots.count) slots, stale \(prices.stale)")

        // Reaching an actuating route through the passthrough is refused and
        // points at the command instead.
        do {
            _ = try await session.api(APIRequest(method: .post, path: "/api/mode", body: Array(#"{"mode":"self_consumption"}"#.utf8)))
            Issue.record("an actuating route answered through the passthrough")
        } catch let refusal as BoxRefusal {
            print("live: POST /api/mode refused with \(refusal.detail.code)")
            #expect(refusal.detail.code == "E_USE_CMD")
        }

        // The mode, set through the command door the box keeps for it.
        if let current = session.state.fields[Contract.FID.mode].flatMap({ Int($0) }), current < session.state.modes.count {
            let key = session.state.modes[current].key
            let result = try await session.command(Contract.opSetMode, args: [("mode", .text(key))])
            print("live: site.mode.set \(key) -> \(result.state.rawValue)")
            #expect(result.state == .applied || result.state == .unconfirmed)
        }
    }
}
