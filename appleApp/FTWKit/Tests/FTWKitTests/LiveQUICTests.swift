import Foundation
import Security
import Testing
@testable import FTWKit

/// The whole app against a real `ftwcloudd` and a real box, over QUIC, over
/// the WebSocket, and racing the two. Off unless the environment names them:
///
///     FTW_LIVE_QUIC_DIR=/path       pair-<n>.url (v3 links the box wrote),
///                                   noise.pub and ca.pem
///     FTW_LIVE_QUIC_URL=wss://127.0.0.1:18543/v1/app
///
/// For each transport it pairs a new phone through FTW Cloud, times the scan
/// to the stream, taps to the box's ack, and the way back from the
/// background, with the relay unreachable. The last line of each is a
/// markdown row.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_QUIC_DIR"] != nil), .serialized)
struct LiveQUICTests {
    let env = ProcessInfo.processInfo.environment
    var dir: URL { URL(fileURLWithPath: env["FTW_LIVE_QUIC_DIR"]!) }
    var label: String { env["FTW_LIVE_QUIC_LABEL"] ?? "local" }

    func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(arguments: ["websocket", "quic", "race"])
    func aPhonePairsStreamsAndCommandsOver(_ mode: String) async throws {
        let pem = try read("ca.pem")
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let endpoint = CloudEndpoint(url: URL(string: env["FTW_LIVE_QUIC_URL"] ?? "wss://127.0.0.1:18543/v1/app")!,
                                     serviceKeys: [try Base64url.decode(read("noise.pub"))])
        let relayURL = URL(string: "wss://127.0.0.1:9")!
        let pinned: WebSocketFactory = { url, events in PinnedWebSocket(url: url, events: events, anchor: anchor) }
        let quic = QUICCloudSocket.factory(anchor: anchor)
        let cloud: WebSocketFactory
        switch mode {
        case "quic": cloud = quic
        case "race": cloud = CloudSockets.racing(quic: quic, webSocket: pinned, scheduler: LiveScheduler.shared,
                                                 memory: CloudTransportMemory(defaults: nil))
        default: cloud = pinned
        }
        let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-live-quic-\(UUID().uuidString)"), store: MemoryStore())
        let app = AppModel(store: MemoryStore(), files: files, passkeys: FakePasskeys(), scheduler: LiveScheduler(),
                           build: "live-quic-test", ua: "test", relayURL: relayURL, cloudEndpoint: endpoint,
                           makeSocket: URLSessionWebSocket.factory(), makeCloudSocket: cloud)

        let link = try await pairingLink()
        await PairModel(app: app).pair(link)
        let site = try #require(app.site)
        let paired = try await until { site.session.phase == .streaming }
        let transport = site.cloudTransport ?? "?"
        #expect(site.carrier == .tunnel)
        // The race may hand one session to the WebSocket on a lossy link;
        // QUIC alone must be QUIC.
        if mode == "quic" { #expect(transport == Contract.transportQUIC) }

        var acks: [Double] = []
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 150_000_000)
            let t0 = Date()
            var ackAt: Date?
            _ = try await site.core.command(Contract.opSetMode, args: [("mode", .text("self_consumption"))],
                                            onAck: { ackAt = Date() })
            if let ackAt { acks.append(ackAt.timeIntervalSince(t0) * 1000) }
        }
        var opens: [Double] = []
        for _ in 0..<6 {
            app.suspend()
            try await Task.sleep(nanoseconds: 400_000_000)
            app.setVisible(true)
            opens.append(try await until { site.session.phase == .streaming && site.carrier == .tunnel } * 1000)
        }
        print("| \(label) | \(mode) → \(transport) | \(String(format: "%.0f", paired * 1000)) | \(q(acks, 0.5)) / \(q(acks, 0.95)) | \(q(opens, 0.5)) / \(q(opens, 1)) |")
        #expect(acks.count == 30)
        app.suspend()
    }

    /// A fresh QR code from the box: it shows one at a time.
    func pairingLink() async throws -> String {
        let url = dir.appendingPathComponent("pair.url")
        try? FileManager.default.removeItem(at: url)
        try "1".write(to: dir.appendingPathComponent("pair.request"), atomically: true, encoding: .utf8)
        _ = try await until { FileManager.default.fileExists(atPath: url.path) }
        return try read("pair.url")
    }

    func until(_ seconds: Double = 20, _ ok: () -> Bool) async throws -> Double {
        let start = Date()
        while !ok() {
            if Date().timeIntervalSince(start) > seconds { throw CancellationError() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return Date().timeIntervalSince(start)
    }

    func q(_ values: [Double], _ p: Double) -> String {
        guard !values.isEmpty else { return "–" }
        let s = values.sorted()
        return String(format: "%.0f", s[Int(Double(s.count - 1) * p)])
    }
}
