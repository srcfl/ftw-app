import Foundation
import Testing
@testable import FTWKit

/// Against a real FTW box, through the production relay.
///
/// Off unless FTW_LIVE_URL holds a pairing URL the box just minted:
///
///     curl -s -X POST localhost:8080/api/app-link/pairing -d '{"role":"owner"}'
///     FTW_LIVE_URL='https://app.ftw.energy/p#v2...' swift test --filter LiveBox
///
/// On Linux, whose Foundation has no WebSocket client, run a bridge that
/// carries frames to the relay unchanged and set FTW_LIVE_RELAY to it.
///
/// The passkey ceremony cannot run here, so the device key is wrapped under
/// the local key alone. Everything after that is the shipped path: the real
/// socket, the rotating handle, Noise IK with the pairing code in message 1,
/// the session, and the box's own API over it.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_URL"] != nil), .serialized)
struct LiveBoxTests {
    @Test func pairsStreamsAndCallsTheBoxOverTheRelay() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["FTW_LIVE_URL"])
        let enrollment = try Enrollment.parse(scanned: url)
        let vault = Vault(store: MemoryStore())
        let device = try vault.deviceKey(vault.localWrappingKey())

        let scheduler = LiveScheduler()
        // FTW_LIVE_RELAY points at a local bridge where Foundation has no
        // WebSocket client of its own (Linux); elsewhere the real socket.
        let relay: RelayCarrier
        if let bridge = ProcessInfo.processInfo.environment["FTW_LIVE_RELAY"], let bridgeURL = URL(string: bridge) {
            #if os(Linux)
            relay = RelayCarrier(url: bridgeURL, secret: enrollment.rendezvousSecret, scheduler: scheduler, makeSocket: PlainWebSocket.factory())
            #else
            relay = RelayCarrier(url: bridgeURL, secret: enrollment.rendezvousSecret, scheduler: scheduler)
            #endif
        } else {
            relay = RelayCarrier(secret: enrollment.rendezvousSecret, scheduler: scheduler)
        }
        let noise = NoiseCarrier(
            inner: relay,
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

        let plan = try await session.plan()
        print("live: plan rev \(plan.rev), \(plan.slots.count) slots, stale \(plan.stale)")

        var tiles = 0
        let end = try await session.history(HistQuery(series: ["grid_w", "pv_w", "battery_w", "load_w"], res: .fiveMinutes, fromMs: Date().timeIntervalSince1970 * 1000 - 86_400_000, toMs: Date().timeIntervalSince1970 * 1000, have: [], maxPoints: 1500)) { _ in tiles += 1 }
        print("live: history \(tiles) tiles, served \(end.resActual.rawValue)")

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
