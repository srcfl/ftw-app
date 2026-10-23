import Foundation
import FTWShared
import FTWWire
import os

/// The watch on its own: reads and commands through FTW Cloud, each one
/// HTTPS request (srcfl/ftw ADR 0009, "Through FTW Cloud"). It works once
/// the phone has added this watch to its box by key and handed over the
/// link (`WatchLink`), and needs the phone for nothing after that.
///
/// - A read is FTW Cloud's copy of the home, signed by the box and dated by
///   the freshness rules (`WatchCloud`). It needs the readable copy on.
/// - A command runs the box's exchange: a handshake, then the `cmd`, each
///   carried as `x`. The box answers itself; FTW Cloud reads neither.
///
/// It reads when asked and never on a timer. One request at a time, as the
/// service allows a device.
@MainActor
final class CloudPath {
    nonisolated static let log = Logger(subsystem: "energy.ftw.app.watchkitapp", category: "cloud")

    private var sink: PathSink?
    /// The phone's link, from the newest context that carried one.
    private(set) var link: WatchLink?
    /// The last request in the queue; the next waits for it.
    private var tail: Task<Void, Never>?
    /// The instance that holds the home, once the service named it.
    private var shard: String?
    /// A read refused (the copy is off, or the watch is not listed) waits
    /// this long before the next, so a wrist raised again and again does
    /// not ask again and again.
    private var readsAfterMs: Double = 0
    private static let refusedWaitMs: Double = 15 * 60_000
    private let endpoint = CloudEndpoint.current
    private let http: URLSession

    private var nowMs: Double { Date.now.timeIntervalSince1970 * 1000 }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        http = URLSession(configuration: config)
    }

    func start(_ sink: @escaping PathSink) {
        self.sink = sink
    }

    /// The watch can reach its box by itself: an endpoint, its own key, and
    /// a link the phone made for this very key.
    var ready: Bool {
        guard endpoint != nil, let link, let key = Self.key() else { return false }
        return Data(key.publicKey) == link.watchKey
    }

    /// The newest link wins; a context without one changes nothing.
    func take(_ next: WatchLink?) {
        guard let next, next != link else { return }
        link = next
    }

    // MARK: Reading

    /// One read of the home, unless one is under way or the last was
    /// refused a moment ago.
    func read(looking: Bool, kept: @escaping @MainActor () -> WatchContext?) async {
        guard ready, let link, link.cloudKey != nil, nowMs >= readsAfterMs else { return }
        do {
            let (payload, following) = try await request(CloudOnce.read(looking: looking))
            let snap = try CloudOnce.snapshot(payload: payload, following: following)
            guard var read = WatchCloud.read(snap, link: link, kept: kept(), arrivalMs: nowMs) else { return }
            // A live Now arrives as a frame, so it glows for as long as the
            // box's grade holds; anything else is ink, with its time.
            if read.liveForMs != nil, let now = read.context.now {
                read.context.now = nil
                sink?(.context(read.context))
                sink?(.news(.now(now)))
            } else {
                sink?(.context(read.context))
            }
            Self.log.info("cloud read: \(snap.envelopes.count, privacy: .public) envelopes, live \(read.liveForMs != nil, privacy: .public)")
        } catch CloudError.refused {
            readsAfterMs = nowMs + Self.refusedWaitMs
            Self.log.notice("cloud read refused; the copy may be off")
        } catch {
            Self.log.notice("cloud read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Commands

    /// Run one command through the box's exchange. Every mark after
    /// sending is the box's own answer; a command that got none is asked
    /// again under its `cmdId`, which the box answers with what it did.
    /// True when the box applied it.
    @discardableResult
    func send(_ c: WatchCommand) async -> Bool {
        // A command for a home other than the one the phone linked goes
        // through the phone or not at all.
        guard ready, let link, c.home == link.site, let key = Self.key() else {
            say(.box(c, .needsPhone))
            return false
        }
        say(.box(c, .sending))
        var step = WatchReceipt.BoxStep.noAnswer
        sessions: for _ in 0..<2 {
            do {
                let session = try ExchangeSession(boxKey: Bytes(link.boxKey), staticKey: key)
                let hello = try await exchange(session.open(build: Self.build))
                guard !hello.isEmpty else { continue }
                let opened = try session.opened(hello)
                let openedAt = nowMs
                guard let cmd = ExchangeSession.cmd(c, link: link, opened: opened, openedAtMs: openedAt, nowMs: nowMs) else {
                    step = c.notValidAfterMs <= nowMs ? .refused(.tooLate) : .needsPhone
                    break sessions
                }
                for ask in 0..<3 {
                    let reply = try await exchange(session.request(cmd))
                    // Silence: the session is gone, or the box away. A new
                    // session asks again.
                    guard !reply.isEmpty else { continue sessions }
                    switch ExchangeSession.outcome(try session.answer(reply), cmdId: c.id) {
                    case .applied:
                        step = .applied
                        break sessions
                    case .refused(let why):
                        step = .refused(why)
                        break sessions
                    case .pending, .unread:
                        step = .pending
                        say(.box(c, .pending))
                        if ask < 2 { try await Task.sleep(for: .milliseconds(1_500)) }
                    }
                }
                break sessions
            } catch {
                Self.log.notice("command through FTW Cloud failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        say(.box(c, step == .pending ? .noAnswer : step))
        return step == .applied
    }

    private func say(_ r: WatchReceipt) {
        sink?(.news(.receipt(r)))
    }

    /// One exchange message to the box and its answer, empty when none
    /// came.
    private func exchange(_ d: Bytes) async throws -> Bytes {
        let (payload, _) = try await request(CloudOnce.x(d))
        return try CloudOnce.xAnswer(payload: payload)
    }

    // MARK: The request

    enum CloudError: Error {
        /// 403: not admitted, or another service key. Says nothing more.
        case refused
        case status(Int)
        case notReady
    }

    /// One request in the queue: the service takes one at a time per
    /// device.
    private func request(_ payload: Bytes) async throws -> (payload: Bytes, following: [Bytes]) {
        let before = tail
        let mine = Task<(Bytes, [Bytes]), Error> { @MainActor in
            await before?.value
            return try await self.post(payload)
        }
        tail = Task { _ = try? await mine.value }
        return try await mine.value
    }

    /// The POST, with the app's other service key once on a refusal, as the
    /// app session does, and the shard the service names once.
    private func post(_ payload: Bytes) async throws -> (Bytes, [Bytes]) {
        guard let endpoint, let link, let key = Self.key() else { throw CloudError.notReady }
        var lastError: Error = CloudError.refused
        for serviceKey in endpoint.serviceKeys {
            for _ in 0..<2 {
                let req = try CloudOnce.Request(home: link.cloudHome, serviceKey: serviceKey, staticKey: key, payload: payload)
                var r = URLRequest(url: CloudOnce.url(endpoint, home: link.cloudHome, host: shard))
                r.httpMethod = "POST"
                r.setValue(CloudOnce.contentType, forHTTPHeaderField: "Content-Type")
                r.httpBody = Data(req.body)
                let (data, response) = try await http.data(for: r)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    return try req.answer(Bytes(data))
                case CloudOnce.wrongShard:
                    guard let host = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: CloudOnce.shardHeader), !host.isEmpty else {
                        throw CloudError.status(status)
                    }
                    shard = host
                    continue
                case 403:
                    lastError = CloudError.refused
                default:
                    throw CloudError.status(status)
                }
                break
            }
        }
        throw lastError
    }

    // MARK: The key

    /// The watch's key, read once. Debug builds may take one from the
    /// launch arguments, for a simulator against a local box:
    /// `-FTWWatchKey <64 hex>`.
    private static func key() -> Primitives.KeyPair? {
        if let cached = cachedKey { return cached }
        #if DEBUG
        if let hex = UserDefaults.standard.string(forKey: "FTWWatchKey"), hex.count == 64 {
            cachedKey = try? Primitives.keyPair(fromSecret: Bytes(hex: hex))
            return cachedKey
        }
        #endif
        cachedKey = WatchIdentity.keyPair()
        return cachedKey
    }

    private static var cachedKey: Primitives.KeyPair?

    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "watch"
}
