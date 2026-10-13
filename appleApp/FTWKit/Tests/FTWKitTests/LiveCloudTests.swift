import Foundation
import Security
import Testing
@testable import FTWKit

/// Against a real FTW box and a real `ftwcloudd`, through the production
/// relay. Off unless the environment names them:
///
///     FTW_LIVE_BOX=http://127.0.0.1:18080          the box's API, on loopback
///     FTW_LIVE_CLOUD_URL=wss://127.0.0.1:18443/v1/app
///     FTW_LIVE_CLOUD_KEY=<the service's Noise key, base64url>
///     FTW_LIVE_CLOUD_CA=/path/to/ca.pem             the local certificate's root
///     FTW_LIVE_CLOUD_STOP='kill …'  FTW_LIVE_CLOUD_START='…'   optional
///
/// It pairs two phones, turns FTW Cloud on as the consent screen does, and
/// times the three layers of a cold start against the relay's path, five
/// times each. It then replays a snapshot an hour late, revokes a phone with
/// its stream open, and closes the cloud under a running home.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FTW_LIVE_CLOUD_URL"] != nil), .serialized)
struct LiveCloudTests {
    let env = ProcessInfo.processInfo.environment
    let scheduler = LiveScheduler()

    var box: URL { URL(string: env["FTW_LIVE_BOX"] ?? "http://127.0.0.1:18080")! }

    var endpoint: CloudEndpoint {
        CloudEndpoint(url: URL(string: env["FTW_LIVE_CLOUD_URL"]!)!, serviceKeys: [try! Base64url.decode(env["FTW_LIVE_CLOUD_KEY"]!)])
    }

    var cloudSockets: WebSocketFactory {
        let pem = try! String(contentsOfFile: env["FTW_LIVE_CLOUD_CA"]!, encoding: .utf8)
        let der = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())!
        let anchor = SecCertificateCreateWithData(nil, der as CFData)!
        return { url, events in PinnedWebSocket(url: url, events: events, anchor: anchor) }
    }

    /// One phone, as the app holds it after pairing.
    struct Phone {
        let enrollment: Enrollment
        let key: Primitives.KeyPair
        var id: String { String(Base64url.encode(key.publicKey).prefix(8)) }
    }

    func pair(_ role: String) async throws -> Phone {
        var req = URLRequest(url: box.appendingPathComponent("api/app-link/pairing"))
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"role":"\#(role)"}"#.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSON(parsing: Bytes(data))
        let url = try #require(json["url"]?.string ?? json["link"]?.string)
        let vault = Vault(store: MemoryStore())
        return Phone(enrollment: try Enrollment.parse(scanned: url), key: try vault.deviceKey(vault.localWrappingKey()))
    }

    func relay(_ phone: Phone) -> NoiseCarrier {
        let e = phone.enrollment
        return NoiseCarrier(
            inner: RelayCarrier(secret: e.rendezvousSecret, scheduler: scheduler),
            staticKey: phone.key, remoteStatic: e.boxStaticPublic,
            prologue: NoiseCarrier.prologue(boxStaticKey: e.boxStaticPublic),
            handshakePayload: e.pairingCode, scheduler: scheduler
        )
    }

    func files() -> SealedFiles {
        SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-live-\(UUID().uuidString)"), store: MemoryStore())
    }

    func site(_ files: SealedFiles) -> SiteModel {
        let s = SiteModel(siteId: "live", build: "live-cloud-test", ua: "test", scheduler: scheduler, files: files)
        s.start()
        return s
    }

    /// Wait for `ok`, polling every 2 ms, and return how long it took.
    func until(_ seconds: Double = 30, _ ok: () -> Bool) async throws -> Double {
        let start = Date()
        while !ok() {
            if Date().timeIntervalSince(start) > seconds { throw Timeout() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return Date().timeIntervalSince(start) * 1000
    }

    struct Timeout: Error {}

    func line(_ name: String, _ ms: [Double]) {
        let sorted = ms.sorted()
        let text = ms.map { String(Int($0.rounded())) }.joined(separator: ", ")
        print("live-cloud: \(name): \(text) ms; median \(Int(sorted[sorted.count / 2].rounded())) ms")
    }

    func shell(_ command: String?) throws {
        guard let command else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try p.run()
        p.waitUntilExit()
    }

    @Test func threeLayersAgainstTheRelayAndTheProofs() async throws {
        // An owner pairs and turns FTW Cloud on over the box session, as the
        // consent screen does.
        let owner = try await pair(Contract.roleOwner)
        let setupFiles = files()
        var home = site(setupFiles)
        home.connect(relay(owner))
        _ = try await until { home.session.phase == .streaming }
        #expect(home.session.caps.contains(Contract.capCloudLink))
        let consent = CloudConsent(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        await consent.accept(home)
        print("live-cloud: grant \(consent.box?.state ?? (home.cloudOn ? "already on" : "?")) \(consent.help ?? "")")
        #expect(consent.box?.on == true || home.cloudOn)
        home.destroy()

        // The next hello names the box's key; the cache keeps it.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        home = site(setupFiles)
        home.connectCloud(deviceKey: owner.key, makeSocket: cloudSockets, endpoint: endpoint)
        home.connect(relay(owner))
        _ = try await until { home.cloudOn && home.carrier == .cloud }
        let identity = try #require(home.cloudIdentity)
        print("live-cloud: home \(identity.home), sources \(identity.sources.values.sorted())")
        home.destroy()

        // Five cold starts of each path, each on new sockets.
        var relayFirst: [Double] = [], cloudSnapshot: [Double] = [], cloudLive: [Double] = [], cachePaint: [Double] = []
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let r = site(files())
            let t0 = Date()
            r.connect(relay(owner))
            _ = try await until { r.session.phase == .streaming && r.lastFrameAtMs != nil }
            relayFirst.append(Date().timeIntervalSince(t0) * 1000)
            r.destroy()
        }
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let f = files()
            f.writeJSON("cloud-live", CloudCache(identity: identity, offset: nil))
            f.writeJSON("snapshot-live", CachedSnapshot(siteId: "live", savedAtMs: Date().timeIntervalSince1970 * 1000 - 60_000, state: home.session))
            let t0 = Date()
            let c = site(f)
            cachePaint.append(Date().timeIntervalSince(t0) * 1000)
            #expect(c.carrier == .cache && !c.session.fields.isEmpty)
            c.connectCloud(deviceKey: owner.key, makeSocket: cloudSockets, endpoint: endpoint)
            _ = try await until { c.carrier == .cloud }
            cloudSnapshot.append(Date().timeIntervalSince(t0) * 1000)
            let snapFrame = c.lastFrameAtMs
            _ = try await until { c.lastFrameAtMs != snapFrame && c.cloudView?.live != nil }
            cloudLive.append(Date().timeIntervalSince(t0) * 1000)
            #expect(c.isLive)
            c.destroy()
        }
        // How often the box sends while a phone looks: the cloud sends on
        // change, at most once a second while watched.
        var arrivals: [(String, Double)] = []
        let watcher = CloudCarrier(endpoint: endpoint, home: identity.home, deviceKey: owner.key, looking: true, scheduler: scheduler, makeSocket: cloudSockets)
        watcher.setHandlers(onSnapshot: { _, _ in }, onEnvelope: { e, at in arrivals.append((e.t, at)) }, onStatus: { _ in })
        watcher.start()
        try await Task.sleep(nanoseconds: 20_000_000_000)
        watcher.close()
        for t in ["live", "lp", "hb", "prices"] {
            let at = arrivals.filter { $0.0 == t }.map(\.1)
            let gaps = zip(at.dropFirst(), at).map { Int(($0 - $1).rounded()) }
            print("live-cloud: watched 20 s: \(t) \(at.count)×, gaps \(gaps) ms")
        }

        line("first frame from the phone's cache", cachePaint)
        line("cloud snapshot (layer 2)", cloudSnapshot)
        line("first cloud update after it (layer 3)", cloudLive)
        line("relay, first reading (today's path)", relayFirst)

        // A replayed snapshot: the real bytes, an hour late, never live.
        var snapshots: [CloudWire.Snapshot] = []
        let raw = CloudCarrier(endpoint: endpoint, home: identity.home, deviceKey: owner.key, looking: true, scheduler: scheduler, makeSocket: cloudSockets)
        raw.setHandlers(onSnapshot: { s, _ in snapshots.append(s) }, onEnvelope: { _, _ in }, onStatus: { _ in })
        raw.start()
        _ = try await until { !snapshots.isEmpty }
        raw.close()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var fresh = CloudView(home: identity.home, boxKey: identity.pk)
        var late = CloudView(home: identity.home, boxKey: identity.pk)
        for e in snapshots[0].envelopes {
            try? fresh.accept(e, arrivalMs: now)
            try? late.accept(e, arrivalMs: now + 3_600_000)
        }
        let g1 = fresh.grade(nowMs: now), g2 = late.grade(nowMs: now + 3_600_000)
        print("live-cloud: replay: now sources \(g1.sources.values.map(\.rawValue).sorted()), an hour late \(g2.sources.values.map(\.rawValue).sorted()), fields \(Set(g2.fields.values.map(\.rawValue)).sorted())")
        #expect(!g2.sources.values.contains(.live) && !g2.fields.values.contains(.live))

        // Revoke a phone with its stream open: closed within a second.
        let viewer = try await pair(Contract.roleViewer)
        let v = site(files())
        v.connect(relay(viewer))
        _ = try await until { v.session.phase == .streaming }
        v.destroy()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var status: CloudCarrier.Status = .connecting
        let vc = CloudCarrier(endpoint: endpoint, home: identity.home, deviceKey: viewer.key, looking: true, scheduler: scheduler, makeSocket: cloudSockets)
        vc.setHandlers(onSnapshot: { _, _ in }, onEnvelope: { _, _ in }, onStatus: { status = $0 })
        vc.start()
        _ = try await until { status.isOpen }
        var del = URLRequest(url: box.appendingPathComponent("api/app-link/devices/\(viewer.id)"))
        del.httpMethod = "DELETE"
        let t0 = Date()
        let (_, resp) = try await URLSession.shared.data(for: del)
        let cut = try await until(5) { !status.isOpen }
        print("live-cloud: revoke: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0), stream closed \(Int(Date().timeIntervalSince(t0) * 1000)) ms after the request (\(Int(cut)) ms after the answer), \(status)")
        #expect(Date().timeIntervalSince(t0) < 1)
        vc.close()

        // The cloud goes away under a running home: the relay takes over
        // under its own name, and the cloud takes back over when it returns.
        guard env["FTW_LIVE_CLOUD_STOP"] != nil else { return }
        let f = files()
        f.writeJSON("cloud-live", CloudCache(identity: identity, offset: nil))
        let both = site(f)
        both.connectCloud(deviceKey: owner.key, makeSocket: cloudSockets, endpoint: endpoint)
        both.connect(relay(owner))
        _ = try await until { both.carrier == .cloud && both.session.phase == .streaming }
        try shell(env["FTW_LIVE_CLOUD_STOP"])
        let down = try await until { both.carrier == .relay }
        print("live-cloud: cloud stopped: carrier \(both.carrier.rawValue) after \(Int(down)) ms, band \"\(both.freshness(noCarrier: false).message)\"")
        try shell(env["FTW_LIVE_CLOUD_START"])
        both.networkOnline()
        let up = try await until(70) { both.carrier == .cloud }
        print("live-cloud: cloud back: carrier \(both.carrier.rawValue) after \(Int(up)) ms, band \"\(both.freshness(noCarrier: false).message)\"")
        both.destroy()
    }
}

/// URLSession's WebSocket, trusting one local root and nothing else, so a
/// test reaches a local `ftwcloudd` without touching the Mac's keychain.
@MainActor
final class PinnedWebSocket: NSObject, WebSocketConnection {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let events: WebSocketEvents
    private var closed = false
    private var opened = false

    init(url: URL, events: WebSocketEvents, anchor: SecCertificate) {
        self.events = events
        super.init()
        let session = URLSession(configuration: .ephemeral, delegate: Delegate(owner: self, anchor: anchor), delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func send(_ data: Bytes) {
        guard !closed, let task else { return }
        task.send(.data(Data(data))) { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch result {
                case .success(.data(let d)):
                    self.didOpen()
                    self.events.onBinary(d.byteArray)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let code = self.task?.closeCode.rawValue ?? 0
                    self.didClose(code == 0 ? 1006 : code)
                }
            }
        }
    }

    fileprivate func didOpen() {
        guard !opened, !closed else { return }
        opened = true
        events.onOpen()
    }

    fileprivate func didClose(_ code: Int) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        events.onClose(code, "")
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: PinnedWebSocket?
        let anchor: SecCertificate

        init(owner: PinnedWebSocket, anchor: SecCertificate) {
            self.owner = owner
            self.anchor = anchor
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            Task { @MainActor [weak owner] in owner?.didOpen() }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            Task { @MainActor [weak owner] in owner?.didClose(closeCode.rawValue) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            Task { @MainActor [weak owner] in owner?.didClose(1006) }
        }
    }
}
