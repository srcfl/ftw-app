import Foundation
import Security
import Testing
@testable import FTWKit

/// The whole app against a real `ftwcloudd` and a real box, with the relay
/// unreachable. Off unless the environment names them:
///
///     FTW_LIVE_TUNNEL_DIR=/path       pair.url (a v3 link the box wrote),
///                                     noise.pub and ca.pem
///     FTW_LIVE_CLOUD_URL=wss://127.0.0.1:18743/v1/app
///
/// It pairs from the v3 link through FTW Cloud, streams, comes back from
/// the background, and times commands from the tap to the box's ack.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_TUNNEL_DIR"] != nil), .serialized)
struct LiveTunnelTests {
    let env = ProcessInfo.processInfo.environment
    var dir: URL { URL(fileURLWithPath: env["FTW_LIVE_TUNNEL_DIR"]!) }

    func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aPhonePairsStreamsAndCommandsThroughFTWCloudWithTheRelayUnreachable() async throws {
        let pem = try read("ca.pem")
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let endpoint = CloudEndpoint(url: URL(string: env["FTW_LIVE_CLOUD_URL"] ?? "wss://127.0.0.1:18743/v1/app")!,
                                     serviceKeys: [try Base64url.decode(read("noise.pub"))])
        // Nothing listens on port 9: the relay is unreachable.
        let relayURL = URL(string: "wss://127.0.0.1:9")!
        var relayDials = 0
        let sockets: WebSocketFactory = { url, events in
            if url.host == relayURL.host, url.port == relayURL.port { relayDials += 1 }
            return url.port == relayURL.port
                ? URLSessionWebSocket.factory()(url, events)
                : PinnedWebSocket(url: url, events: events, anchor: anchor)
        }
        let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-live-tunnel-\(UUID().uuidString)"), store: MemoryStore())
        let app = AppModel(store: MemoryStore(), files: files, passkeys: FakePasskeys(), scheduler: LiveScheduler(),
                           build: "live-tunnel-test", ua: "test", cloudEndpoint: endpoint, makeSocket: sockets)

        let link = try read("pair.url")
        #expect(link.contains("#v3."))
        await PairModel(app: app).pair(link)
        let site = try #require(app.site)
        let paired = try await until { site.session.phase == .streaming }
        print("tunnel: scan to streaming \(ms(paired)) (pairing through FTW Cloud), carrier \(site.carrier), relay dials \(relayDials)")
        #expect(site.carrier == .tunnel)
        #expect(relayDials == 0)
        #expect(site.session.caps.contains(Contract.capCloudTun))
        #expect(app.sites.get(try #require(site.siteId))?.cloudHome != nil)

        // Tap to the box's ack, and to its result, one command at a time.
        var acks: [Double] = [], results: [Double] = []
        for i in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let t0 = Date()
            var ackAt: Date?
            let result = try await site.core.command(Contract.opSetMode, args: [("mode", .text("self_consumption"))],
                                                     onAck: { ackAt = Date() })
            results.append(Date().timeIntervalSince(t0) * 1000)
            if let ackAt { acks.append(ackAt.timeIntervalSince(t0) * 1000) }
            #expect(result.state != .unconfirmed, "\(i)")
        }
        print("tunnel: tap to cmd.ack median \(q(acks, 0.5)) p95 \(q(acks, 0.95)) max \(q(acks, 1)) ms (n=\(acks.count))")
        print("tunnel: tap to cmd.result median \(q(results, 0.5)) p95 \(q(results, 0.95)) max \(q(results, 1)) ms (n=\(results.count))")
        #expect(acks.count == 50)

        // Back from the background, five times: the box said cloud.tun, so
        // the tunnel again, with no proof and no relay.
        var opens: [Double] = []
        for _ in 0..<5 {
            app.suspend()
            try await Task.sleep(nanoseconds: 300_000_000)
            app.setVisible(true)
            opens.append(try await until { site.session.phase == .streaming && site.carrier == .tunnel })
        }
        print("tunnel: foreground to streaming \(opens.map { String(format: "%.0f", $0 * 1000) }.joined(separator: ", ")) ms; relay dials \(relayDials)")
        #expect(relayDials == 0)
        #expect(site.carrier == .tunnel)
        try? "done".write(to: dir.appendingPathComponent("stop"), atomically: true, encoding: .utf8)
    }

    /// Wait for `ok`, polling every 2 ms, and return how long it took.
    func until(_ seconds: Double = 20, _ ok: () -> Bool) async throws -> Double {
        let start = Date()
        while !ok() {
            if Date().timeIntervalSince(start) > seconds { throw CancellationError() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return Date().timeIntervalSince(start)
    }

    func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

    func q(_ values: [Double], _ p: Double) -> String {
        guard !values.isEmpty else { return "-" }
        let s = values.sorted()
        return String(format: "%.1f", s[Int(Double(s.count - 1) * p)])
    }
}
