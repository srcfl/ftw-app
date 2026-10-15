import Foundation
import Security
import Testing
@testable import FTWKit

/// How long a reading takes from the box's driver to this session's decode,
/// against a real `ftwcloudd` and the box srcfl/ftw runs as
/// `TestLiveBoxForTheiPhone` (go/internal/appuplink), whose grid reading is
/// the wall-clock millisecond it arrived. Off unless the environment names
/// them:
///
///     FTW_LIVE_LATENCY_DIR=/path      the box's directory: pair.url,
///                                     noise.pub and ca.pem; decode.log and
///                                     open.log are written here
///     FTW_LIVE_CLOUD_URL=wss://127.0.0.1:18843/v1/app
///     FTW_LIVE_LATENCY_SECONDS=120    per phase, visible and hidden
///
/// Each decoded grid reading is logged with the wall clock in microseconds,
/// so a script pairs it with the box's own log of arrivals.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_LATENCY_DIR"] != nil), .serialized)
struct LiveLatencyTests {
    let env = ProcessInfo.processInfo.environment
    var dir: URL { URL(fileURLWithPath: env["FTW_LIVE_LATENCY_DIR"]!) }

    func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The grid readings this session decoded, and when.
    @MainActor final class Decodes {
        var phase = "pair"
        var last: Double?
        var lines: [String] = []

        func watch(_ core: Session) {
            let inner = core.onChange
            core.onChange = { [self] s in
                if s.carrier == .tunnel, let v = s.fields[2], v != last {
                    last = v
                    lines.append("\(Int64(Date().timeIntervalSince1970 * 1_000_000)) \(Int64(v)) \(phase)")
                }
                inner?(s)
            }
        }
    }

    @Test func readingsFromTheDriverToTheDecode() async throws {
        let pem = try read("ca.pem")
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let endpoint = CloudEndpoint(url: URL(string: env["FTW_LIVE_CLOUD_URL"] ?? "wss://127.0.0.1:18843/v1/app")!,
                                     serviceKeys: [try Base64url.decode(read("noise.pub"))])
        let relayURL = URL(string: "wss://127.0.0.1:9")!
        let sockets: WebSocketFactory = { url, events in
            url.port == relayURL.port
                ? URLSessionWebSocket.factory()(url, events)
                : PinnedWebSocket(url: url, events: events, anchor: anchor)
        }
        let store = MemoryStore()
        let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-live-latency-\(UUID().uuidString)"), store: store)
        func model() -> AppModel {
            AppModel(store: store, files: files, passkeys: FakePasskeys(), scheduler: LiveScheduler(),
                     build: "live-latency-test", ua: "test", relayURL: relayURL, cloudEndpoint: endpoint, makeSocket: sockets)
        }
        let app = model()
        await PairModel(app: app).pair(try read("pair.url"))
        let site = try #require(app.site)
        _ = try await until { site.session.phase == .streaming && site.carrier == .tunnel }

        let seconds = UInt64(env["FTW_LIVE_LATENCY_SECONDS"] ?? "120") ?? 120
        let decodes = Decodes()
        decodes.watch(site.core)
        decodes.phase = "visible"
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        decodes.phase = "hidden"
        site.setVisible(false)
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        try decodes.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("decode.log"), atomically: true, encoding: .utf8)
        print("latency: \(decodes.lines.count) grid readings decoded")

        // Cold opens: a new app over the same store, from launch to the
        // first reading the box sent through FTW Cloud.
        app.suspend()
        var opens: [String] = []
        for i in 0..<10 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let cold = model()
            let t0 = Date()
            cold.launch()
            let s = try #require(cold.site)
            let firstLive = Decodes()
            firstLive.phase = "open"
            firstLive.watch(s.core)
            let streaming = try await until { s.session.phase == .streaming && s.carrier == .tunnel }
            let live = try await until { !firstLive.lines.isEmpty }
            opens.append("\(i) \(Int((streaming) * 1000)) \(Int((Date().timeIntervalSince(t0)) * 1000)) \(Int(live * 1000))")
            cold.suspend()
        }
        try opens.joined(separator: "\n").write(to: dir.appendingPathComponent("open.log"), atomically: true, encoding: .utf8)
        print("latency: cold open (i, to streaming ms, to first new reading ms):\n\(opens.joined(separator: "\n"))")
        try? "done".write(to: dir.appendingPathComponent("stop"), atomically: true, encoding: .utf8)
    }

    /// Wait for `ok`, polling every 1 ms, and return how long it took.
    func until(_ seconds: Double = 20, _ ok: () -> Bool) async throws -> Double {
        let start = Date()
        while !ok() {
            if Date().timeIntervalSince(start) > seconds { throw CancellationError() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return Date().timeIntervalSince(start)
    }
}
