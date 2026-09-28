import Foundation

/// The session: handshake, subscription and the field register.
///
/// Owns exactly one carrier at a time and turns frames into state.
/// Everything above reads state; nothing above touches a frame.
///
/// Freshness is two facts, never one: `carrier`, how frames are reaching us,
/// and `sources`, whether the box's own devices are answering.
public enum SessionPhase: String, Sendable {
    case idle, handshaking, subscribing, streaming, booting, terminated, failed
}

public struct SessionState: Sendable {
    public var phase: SessionPhase = .idle
    public var carrier: CarrierKind = .none
    public var proto: Int = Proto.max
    public var mode: BoxMode = .full
    public var caps: Set<String> = []
    /// What this enrolment may do, as the box named it. Read only to decide
    /// what to draw. A box from before roles sends nothing and treats every
    /// paired phone as an owner, so that is what absent means.
    public var role: String = Contract.roleOwner
    /// That role expanded, as the box expanded it. What a control is checked
    /// against; `role` is what a sentence names.
    public var scopes: Set<String> = Set(Contract.roleScopes[Contract.roleOwner] ?? [])
    /// Whether the box has answered a hello since the app opened. Before
    /// that, role and caps are this app's opening assumptions, and a screen
    /// that states something about the box from them would be inventing it.
    public var heardFromBox = false
    public var box: BoxInfo?
    /// Box uptime at the last frame. All ages are deltas against this.
    public var uptimeMs: Double = 0
    public var controlRev: UInt64 = 0
    public var fields: [Int: Double] = [:]
    public var dict: [Int: FieldDef] = [:]
    public var sources: [String: Source] = [:]
    public var dispatchBlockedBy: [String] = []
    public var boot: BootProgress?
    public var lastError: ErrorMsg?
    public var terminated: TerminateReason?
    /// The box says this app is too old for everything.
    public var needsUpdate = false
    /// What the box intends to do. The box pushes a fresh one unasked after
    /// a mode change, so it lives here rather than only as an answer.
    public var plan: Plan?
    /// The last delta could not carry every changed field. Not a fault.
    public var truncated = false
    /// Every mode the box accepts, in its order. Field 1 indexes this list.
    public var modes: [ModeInfo] = []

    public init() {}
}

public struct Subscription: Equatable, Sendable {
    /// Lane 0 bucket, fixed for the session.
    public var bucket: Int = 512
    /// 1 while someone can see it, 0.2 while hidden.
    public var hz: Double = 1

    public init(bucket: Int = 512, hz: Double = 1) {
        self.bucket = bucket
        self.hz = hz
    }

    var cbor: CBOR { .map([("bucket", .int(bucket)), ("hz", .number(hz))]) }
}

/// Errors carry what a screen needs, never a code it would have to render.
public enum SessionError: Error, Equatable {
    case noCarrier
    case carrierClosed
    case timedOut(String)
    case outOfOrder
    case noStatus
    case queueTimedOut
}

/// The box answered a request with a stable code instead of an answer.
public struct BoxRefusal: Error, Equatable {
    public let detail: ErrorMsg
}

/// A command's fate as a sentence the person can act on.
public struct CommandError: Error, Equatable, HelpfulError {
    public let code: String
    public let help: String
}

@MainActor
public final class Session {
    /// History over a relay can be dozens of bulk frames; the point is that
    /// the request always settles, not that it fails fast.
    public static let historyTimeoutMs: Double = 20_000
    public static let apiTimeoutMs: Double = 20_000
    public static let planTimeoutMs: Double = 8_000
    public static let priceTimeoutMs: Double = 8_000
    /// A box that is starting refuses a subscription and does not announce
    /// when it is ready, so the session asks again on its own.
    public static let bootRetryMs: Double = 5_000
    /// Two minutes of box uptime: survives a slow relay, and a command queued
    /// in a tunnel is refused rather than acted on as though new.
    public static let cmdValidForMs: Double = 120_000
    public static let cmdAckTimeoutMs: Double = 5_000
    public static let cmdConfirmTimeoutMs: Double = 15_000
    public nonisolated static let apiMaxBytes = 8 * 1024 * 1024

    public private(set) var state = SessionState() {
        didSet { onChange?(state) }
    }

    /// One listener: the site model. Called after every change.
    public var onChange: (@MainActor (SessionState) -> Void)?

    private let build: String
    private let ua: String
    private let locales: [String]
    private let scheduler: Scheduler
    private var carrier: Carrier?
    private var subscription: Subscription
    private var helloSub: Subscription?
    private var nextRequestID: UInt32 = 1
    private var bootRetry: Cancellable?

    private struct PendingHistory {
        var onChunk: @MainActor (HistChunk) -> Void
        var continuation: CheckedContinuation<HistEnd, Error>
        var timer: Cancellable?
    }

    private struct PendingSingle<T> {
        var continuation: CheckedContinuation<T, Error>
        var timer: Cancellable?
    }

    private struct PendingAPI {
        var continuation: CheckedContinuation<APIResponse, Error>
        var timer: Cancellable?
        var head: (status: Int, headers: [String: String])?
        var chunks: Bytes = []
        var nextSeq: Int = 0
    }

    private struct PendingCommand {
        var continuation: CheckedContinuation<CmdResult, Error>
        var ackTimer: Cancellable
        var confirmTimer: Cancellable
        var acked = false
    }

    private var pendingHistory: [UInt32: PendingHistory] = [:]
    private var pendingPlan: [UInt32: PendingSingle<Plan>] = [:]
    private var pendingPrices: [UInt32: PendingSingle<Prices>] = [:]
    private var pendingAPI: [UInt32: PendingAPI] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]

    // The api queue: one call on the wire at a time, because that is how
    // many the box serves.
    private var apiBusy = false
    private var apiWaiters: [(id: Int, continuation: CheckedContinuation<Void, Error>, timer: Cancellable)] = []
    private var apiWaiterSeq = 0
    private var apiGeneration = 0

    public init(build: String, ua: String = "native", locales: [String] = ["en"], subscription: Subscription = Subscription(), scheduler: Scheduler) {
        self.build = build
        self.ua = ua
        self.locales = locales
        self.subscription = subscription
        self.scheduler = scheduler
    }

    // MARK: Lifecycle

    /// Seed state from the cache before any carrier exists. The readings
    /// were true when captured and the band says how long ago; carrier stays
    /// `cache`, which is a carrier and not a failure.
    ///
    /// The cache read races the connect. Landing mid-handshake, only the
    /// data paints: the phase, carrier and clock belong to the connection.
    public func restore(_ snapshot: CachedSnapshot) {
        switch state.phase {
        case .streaming:
            return
        case .handshaking, .subscribing, .booting:
            if !state.fields.isEmpty { return }
            var s = state
            snapshot.apply(to: &s, includeClock: false)
            state = s
        default:
            var s = state
            snapshot.apply(to: &s, includeClock: true)
            s.phase = .idle
            s.carrier = .cache
            state = s
        }
    }

    /// Attach a carrier and start the handshake. Replaces any current one.
    public func connect(_ next: Carrier) {
        detach()
        // Keep the readings, but drop the old transport claim now: an old
        // stream must never read as live while the new carrier dials.
        var s = state
        s.phase = .idle
        s.carrier = .none
        state = s
        carrier = next
        next.setHandlers(
            onFrame: { [weak self] bytes in self?.onFrame(bytes) },
            onStatus: { [weak self, weak next] status in
                guard let self, let next, self.carrier === next else { return }
                self.onCarrierStatus(status, kind: next.kind)
            }
        )
        if next.status.isOpen {
            onCarrierStatus(next.status, kind: next.kind)
        }
    }

    public func close() {
        detach()
        var s = state
        s.phase = .idle
        s.carrier = .none
        state = s
    }

    /// Match lane 0 to whether anybody can see it. The bucket stays fixed.
    public func setTelemetryHz(_ hz: Double) {
        if subscription.hz == hz { return }
        subscription.hz = hz
        if state.phase == .subscribing || state.phase == .streaming { sendSub() }
    }

    /// Ask the carrier stack to replace a path that may have slept stale.
    @discardableResult
    public func wake() -> Bool {
        guard let carrier else { return false }
        carrier.wake()
        return true
    }

    public var hasCarrier: Bool { carrier != nil }

    // MARK: Freshness

    /// Age of a source's last good reading, in ms of box uptime. Nil when the
    /// two numbers come from different boots: unknown, not "just now".
    public func ageOf(_ srcId: String) -> Double? {
        guard let src = state.sources[srcId] else { return nil }
        let age = state.uptimeMs - src.lastOkMs
        return age < 0 ? nil : age
    }

    /// Worst state across the given sources.
    public func worstSourceState(_ ids: [String]) -> SourceState {
        ids.map { state.sources[$0]?.state ?? .never }.max() ?? .live
    }

    // MARK: Requests

    private func takeRequestID() -> UInt32 {
        let id = nextRequestID
        // u32, and wrapping is harmless: a request that old has settled.
        nextRequestID = nextRequestID == UInt32.max ? 1 : nextRequestID + 1
        return id
    }

    /// A history window. Chunks arrive as they land; the call returns on
    /// `hist.end`. Bulk lane: a query carrying a `have` list varies in length.
    public func history(_ query: HistQuery, onChunk: @escaping @MainActor (HistChunk) -> Void) async throws -> HistEnd {
        guard carrier != nil else { throw SessionError.noCarrier }
        let id = takeRequestID()
        let frame = try Frame.encodeBulk(envelope: Envelope(t: "hist.query", id: id, b: query.cbor))
        // Registered before the frame leaves, so an answer can never arrive
        // for a request nobody is holding.
        return try await withCheckedThrowingContinuation { cont in
            pendingHistory[id] = PendingHistory(onChunk: onChunk, continuation: cont, timer: nil)
            armHistory(id)
            carrier?.send(frame)
        }
    }

    public func plan() async throws -> Plan {
        guard carrier != nil else { throw SessionError.noCarrier }
        let id = takeRequestID()
        let frame = try Frame.encodeBulk(envelope: Envelope(t: "plan.get", id: id))
        return try await withCheckedThrowingContinuation { cont in
            let timer = scheduler.after(Self.planTimeoutMs) { [weak self] in
                guard let p = self?.pendingPlan.removeValue(forKey: id) else { return }
                p.continuation.resume(throwing: SessionError.timedOut("plan"))
            }
            pendingPlan[id] = PendingSingle(continuation: cont, timer: timer)
            carrier?.send(frame)
        }
    }

    /// Prices across a window. Wall clock, unlike every age: prices are
    /// about hours a person plans around.
    public func prices(fromMs: Double, toMs: Double) async throws -> Prices {
        guard carrier != nil else { throw SessionError.noCarrier }
        let id = takeRequestID()
        let frame = try Frame.encodeBulk(envelope: Envelope(t: "price.get", id: id, b: .map([("fromMs", .ms(fromMs)), ("toMs", .ms(toMs))])))
        return try await withCheckedThrowingContinuation { cont in
            let timer = scheduler.after(Self.priceTimeoutMs) { [weak self] in
                guard let p = self?.pendingPrices.removeValue(forKey: id) else { return }
                p.continuation.resume(throwing: SessionError.timedOut("prices"))
            }
            pendingPrices[id] = PendingSingle(continuation: cont, timer: timer)
            carrier?.send(frame)
        }
    }

    /// Call the box's own HTTP API. A 404 is an answer here, not a failure;
    /// `BoxRefusal` means the passthrough refused and no handler ran.
    ///
    /// One call on the wire at a time. The queue is released on settle, not
    /// success, and a call never crosses a disconnect into a new session.
    public func api(_ req: APIRequest) async throws -> APIResponse {
        let generation = apiGeneration
        try await acquireAPISlot()
        defer { releaseAPISlot() }
        for attempt in 0... {
            if generation != apiGeneration { throw SessionError.carrierClosed }
            do {
                return try await dispatchAPI(req)
            } catch let refusal as BoxRefusal {
                // The box can send its last frame before releasing its slot.
                // Only this explicit refusal proves no handler ran; never
                // retry anything else.
                guard refusal.detail.code == "E_UNAVAILABLE",
                      refusal.detail.args["reason"]?.string == "busy",
                      refusal.detail.retryable, attempt < 3 else { throw refusal }
                try await sleep(250 * pow(2, Double(attempt)))
            }
        }
        throw SessionError.carrierClosed
    }

    private func sleep(_ ms: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            scheduler.after(ms) { cont.resume() }
        }
    }

    private func acquireAPISlot() async throws {
        if !apiBusy {
            apiBusy = true
            return
        }
        apiWaiterSeq += 1
        let mine = apiWaiterSeq
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let timer = scheduler.after(Self.apiTimeoutMs) { [weak self] in
                guard let self, let i = self.apiWaiters.firstIndex(where: { $0.id == mine }) else { return }
                self.apiWaiters.remove(at: i)
                cont.resume(throwing: SessionError.queueTimedOut)
            }
            apiWaiters.append((mine, cont, timer))
        }
    }

    private func releaseAPISlot() {
        if apiWaiters.isEmpty {
            apiBusy = false
            return
        }
        let next = apiWaiters.removeFirst()
        next.timer.cancel()
        next.continuation.resume()
    }

    private func dispatchAPI(_ req: APIRequest) async throws -> APIResponse {
        guard let carrier else { throw SessionError.noCarrier }
        if case .closed = carrier.status { throw SessionError.carrierClosed }
        let id = takeRequestID()
        let frame = try Frame.encodeBulk(envelope: Envelope(t: "api.req", id: id, b: req.cbor))
        return try await withCheckedThrowingContinuation { cont in
            pendingAPI[id] = PendingAPI(continuation: cont)
            armAPI(id)
            carrier.send(frame)
        }
    }

    /// Express an intent and follow it to its outcome. Three deadlines,
    /// because they are three events: no ack means it never reached the box;
    /// ack but no result means the hardware has not confirmed; a result is
    /// what actually happened.
    public func command(_ op: String, args: [(String, CBOR)], guards: [Guard] = []) async throws -> CmdResult {
        guard let carrier else { throw SessionError.noCarrier }
        let cmdId = Self.uuidv7(nowMs: scheduler.nowMs)
        let body = CBOR.map([
            ("cmdId", .text(cmdId)),
            ("op", .text(op)),
            ("args", .map(args)),
            // Box uptime, the only clock both ends agree on.
            ("notValidAfterMs", .ms(state.uptimeMs + Self.cmdValidForMs)),
            ("expect", .map([
                ("rev", .unsigned(state.controlRev)),
                ("guards", .array(guards.map { .map([("fid", .int($0.fid)), ("op", .text($0.op)), ("value", .number($0.value))]) })),
            ])),
        ])
        let frame = try Frame.encode(lane: Frame.laneControl, envelope: Envelope(t: "cmd", b: body), bucket: subscription.bucket)
        return try await withCheckedThrowingContinuation { cont in
            let ackTimer = scheduler.after(Self.cmdAckTimeoutMs) { [weak self] in
                guard let self, let p = self.pendingCommands[cmdId], !p.acked else { return }
                self.pendingCommands[cmdId] = nil
                p.confirmTimer.cancel()
                p.continuation.resume(throwing: CommandError(code: "E_NO_ACK", help: "That didn't reach your box. Try again."))
            }
            let confirmTimer = scheduler.after(Self.cmdConfirmTimeoutMs) { [weak self] in
                guard let self, let p = self.pendingCommands[cmdId], p.acked else { return }
                self.pendingCommands[cmdId] = nil
                // Accepted, never confirmed: not a failure and not a success,
                // and the screen has to be able to say so.
                p.continuation.resume(returning: CmdResult(cmdId: cmdId, state: .unconfirmed))
            }
            pendingCommands[cmdId] = PendingCommand(continuation: cont, ackTimer: ackTimer, confirmTimer: confirmTimer)
            carrier.send(frame)
        }
    }

    /// UUIDv7: time-ordered, so the box can expire idempotency keys by prefix.
    static func uuidv7(nowMs: Double) -> String {
        var bytes = randomBytes(16)
        let ms = UInt64(max(0, nowMs))
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: ms >> UInt64(8 * (5 - i))) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let h = bytes.hex
        let c = Array(h)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20...]))"
    }

    // MARK: Frames in

    private func onCarrierStatus(_ status: CarrierStatus, kind: CarrierKind) {
        switch status {
        case .open:
            var s = state
            s.phase = .handshaking
            s.carrier = kind
            state = s
            sendHello()
        case .closed:
            // Losing the carrier does not clear the readings. They are still
            // true, just older, and the band says so.
            var s = state
            s.phase = .failed
            s.carrier = .none
            state = s
            bootRetry?.cancel()
            // The ordinary way a carrier goes away: it reconnects inside
            // itself, keeping its handlers. Every request in flight ends now,
            // so no view waits out a deadline against a reply that cannot come.
            settlePending()
        case .connecting:
            break
        }
    }

    private func onFrame(_ bytes: Bytes) {
        // A frame that does not parse is not a reason to tear down a working
        // session; the next one may be fine.
        guard let frame = try? Frame.decode(bytes) else { return }
        let env = frame.envelope
        let body = env.b ?? CBOR.emptyMap
        switch env.t {
        case "hello_ok": onHelloOk(HelloOk(body))
        case "snap": onSnap(Snap(body))
        case "delta": onDelta(Delta(body), truncated: frame.truncated)
        case "tick":
            var s = state
            s.uptimeMs = body["uptimeMs"]?.double ?? s.uptimeMs
            state = s
        case "hist.chunk":
            guard let id = env.id, let chunk = HistChunk(body), let pending = pendingHistory[id] else { return }
            // A window still arriving is not a window gone quiet.
            armHistory(id)
            pending.onChunk(chunk)
        case "hist.end":
            guard let id = env.id, let pending = pendingHistory.removeValue(forKey: id) else { return }
            pending.timer?.cancel()
            pending.continuation.resume(returning: HistEnd(body))
        case "plan":
            let plan = Plan(body)
            var s = state
            s.plan = plan
            state = s
            if let id = env.id, let pending = pendingPlan.removeValue(forKey: id) {
                pending.timer?.cancel()
                pending.continuation.resume(returning: plan)
            }
        case "price":
            guard let id = env.id, let pending = pendingPrices.removeValue(forKey: id) else { return }
            pending.timer?.cancel()
            pending.continuation.resume(returning: Prices(body))
        case "api.head": onAPIHead(env.id, body)
        case "api.chunk": onAPIChunk(env.id, body)
        case "api.end": onAPIEnd(env.id, body)
        case "cmd.ack":
            guard let cmdId = body["cmdId"]?.string, var p = pendingCommands[cmdId] else { return }
            p.ackTimer.cancel()
            p.acked = true
            pendingCommands[cmdId] = p
        case "cmd.result":
            let result = CmdResult(body)
            guard let p = pendingCommands.removeValue(forKey: result.cmdId) else { return }
            p.ackTimer.cancel()
            p.confirmTimer.cancel()
            p.continuation.resume(returning: result)
        case "error": onError(ErrorMsg(body), id: env.id)
        case "session.terminate":
            var s = state
            s.phase = .terminated
            s.terminated = body["reason"]?.string.flatMap(TerminateReason.init(rawValue:)) ?? .superseded
            s.carrier = .none
            state = s
            detach()
        default:
            // Unknown types are ignored: a newer box talking to this app.
            break
        }
    }

    private func onHelloOk(_ b: HelloOk) {
        var s = state
        s.proto = b.proto
        s.mode = b.mode
        s.caps = Set(b.caps)
        s.role = b.role ?? Contract.roleOwner
        // The box's own expansion, never this app's, except for a box from
        // before roles that sends no list at all.
        s.scopes = Set(b.scopes ?? Contract.roleScopes[b.role ?? Contract.roleOwner] ?? [])
        s.heardFromBox = true
        s.modes = b.modes
        s.box = b.box
        s.uptimeMs = b.uptimeMs
        s.boot = b.boot
        s.needsUpdate = b.hint == "app_update" || b.proto == Proto.floor
        if b.mode == .booting {
            s.phase = .booting
            state = s
            bootRetry?.cancel()
            bootRetry = scheduler.after(Self.bootRetryMs) { [weak self] in self?.sendHello() }
            return
        }
        s.phase = .subscribing
        state = s
        if b.subscribed {
            // Visibility can change while hello crosses the relay; send only
            // if the ask has moved since then.
            if helloSub != subscription { sendSub() }
            return
        }
        // An older box ignored hello.sub and needs the separate exchange.
        sendSub()
    }

    private func onSnap(_ b: Snap) {
        var s = state
        s.phase = .streaming
        if let carrier { s.carrier = carrier.kind }
        s.uptimeMs = b.uptimeMs
        s.controlRev = b.controlRev
        s.dict = b.dict
        s.fields = b.fields
        s.sources = b.sources
        s.dispatchBlockedBy = b.dispatchBlockedBy
        state = s
    }

    private func onDelta(_ b: Delta, truncated: Bool) {
        // A gap means frames were lost. The values held are still true, so
        // what arrived is applied rather than blanking the screen.
        var s = state
        s.phase = .streaming
        s.uptimeMs = b.uptimeMs
        for (k, v) in b.fields { s.fields[k] = v }
        s.truncated = truncated
        if let sources = b.sources { s.sources = sources }
        if let blocked = b.dispatchBlockedBy { s.dispatchBlockedBy = blocked }
        state = s
    }

    private func onAPIHead(_ id: UInt32?, _ body: CBOR) {
        guard let id, var p = pendingAPI[id] else { return }
        // A second status for one request: the first is the one committed to.
        if p.head != nil { return }
        var headers = [String: String]()
        for e in body["headers"]?.entries ?? [] {
            if let k = e.key.string, let v = e.value.string { headers[k.lowercased()] = v }
        }
        p.head = (body["status"]?.int ?? 0, headers)
        pendingAPI[id] = p
        armAPI(id)
    }

    private func onAPIChunk(_ id: UInt32?, _ body: CBOR) {
        guard let id, var p = pendingAPI[id] else { return }
        // A body assembled out of order is bytes that were never sent,
        // presented as the box's. Fail the request instead.
        guard body["seq"]?.int == p.nextSeq else {
            pendingAPI[id] = nil
            p.timer?.cancel()
            p.continuation.resume(throwing: SessionError.outOfOrder)
            return
        }
        p.nextSeq += 1
        p.chunks += body["data"]?.byteString ?? []
        pendingAPI[id] = p
        armAPI(id)
    }

    private func onAPIEnd(_ id: UInt32?, _ body: CBOR) {
        guard let id, let p = pendingAPI.removeValue(forKey: id) else { return }
        p.timer?.cancel()
        // Half a document is wrong in a way no caller above can see.
        if body["truncated"]?.bool == true {
            p.continuation.resume(throwing: BoxRefusal(detail: ErrorMsg(code: "E_RESPONSE_TOO_LARGE", retryable: false, args: ["bytes": body["bytes"] ?? .null])))
            return
        }
        guard let head = p.head else {
            p.continuation.resume(throwing: SessionError.noStatus)
            return
        }
        p.continuation.resume(returning: APIResponse(status: head.status, headers: head.headers, body: p.chunks))
    }

    /// An error carrying a request id belongs to that request alone, so one
    /// window the box could not serve never makes the whole app look broken.
    private func onError(_ b: ErrorMsg, id: UInt32?) {
        if let id {
            if let p = pendingHistory.removeValue(forKey: id) {
                p.timer?.cancel()
                p.continuation.resume(throwing: BoxRefusal(detail: b))
                return
            }
            if let p = pendingPlan.removeValue(forKey: id) {
                p.timer?.cancel()
                p.continuation.resume(throwing: BoxRefusal(detail: b))
                return
            }
            if let p = pendingPrices.removeValue(forKey: id) {
                p.timer?.cancel()
                p.continuation.resume(throwing: BoxRefusal(detail: b))
                return
            }
            if let p = pendingAPI.removeValue(forKey: id) {
                p.timer?.cancel()
                p.continuation.resume(throwing: BoxRefusal(detail: b))
                return
            }
        }
        var s = state
        s.lastError = b
        state = s
    }

    // MARK: Frames out

    private func sendHello() {
        // Any hello supersedes a retry waiting to send one.
        bootRetry?.cancel()
        helloSub = subscription
        send(Envelope(t: "hello", b: .map([
            ("proto", .map([("min", .int(Proto.min)), ("max", .int(Proto.max))])),
            ("app", .map([("build", .text(build)), ("ua", .text(ua))])),
            ("locales", .array(locales.map { .text($0) })),
            ("sub", subscription.cbor),
        ])))
    }

    private func sendSub() {
        send(Envelope(t: "sub", b: subscription.cbor))
    }

    private func send(_ envelope: Envelope) {
        guard let carrier, let frame = try? Frame.encode(lane: Frame.laneControl, envelope: envelope, bucket: subscription.bucket) else { return }
        carrier.send(frame)
    }

    // MARK: Deadlines

    /// The deadline measures silence, not total time: every chunk re-arms it.
    private func armHistory(_ id: UInt32) {
        guard var p = pendingHistory[id] else { return }
        p.timer?.cancel()
        p.timer = scheduler.after(Self.historyTimeoutMs) { [weak self] in
            guard let p = self?.pendingHistory.removeValue(forKey: id) else { return }
            p.continuation.resume(throwing: SessionError.timedOut("history"))
        }
        pendingHistory[id] = p
    }

    private func armAPI(_ id: UInt32) {
        guard var p = pendingAPI[id] else { return }
        p.timer?.cancel()
        p.timer = scheduler.after(Self.apiTimeoutMs) { [weak self] in
            guard let p = self?.pendingAPI.removeValue(forKey: id) else { return }
            p.continuation.resume(throwing: SessionError.timedOut("api"))
        }
        pendingAPI[id] = p
    }

    private func detach() {
        bootRetry?.cancel()
        if let carrier {
            carrier.setHandlers(onFrame: { _ in }, onStatus: { _ in })
            carrier.close(reason: "closed by client")
        }
        carrier = nil
        settlePending()
    }

    /// End everything waiting on a carrier that will not answer. A command
    /// is settled the way its own deadlines would settle it: never acked
    /// means it did not reach the box; acked means it may well have run.
    private func settlePending() {
        apiGeneration += 1
        for (_, p) in pendingHistory { p.timer?.cancel(); p.continuation.resume(throwing: SessionError.carrierClosed) }
        pendingHistory = [:]
        for (_, p) in pendingPlan { p.timer?.cancel(); p.continuation.resume(throwing: SessionError.carrierClosed) }
        pendingPlan = [:]
        for (_, p) in pendingPrices { p.timer?.cancel(); p.continuation.resume(throwing: SessionError.carrierClosed) }
        pendingPrices = [:]
        for (_, p) in pendingAPI { p.timer?.cancel(); p.continuation.resume(throwing: SessionError.carrierClosed) }
        pendingAPI = [:]
        let commands = pendingCommands
        pendingCommands = [:]
        for (cmdId, p) in commands {
            p.ackTimer.cancel()
            p.confirmTimer.cancel()
            if p.acked {
                p.continuation.resume(returning: CmdResult(cmdId: cmdId, state: .unconfirmed))
            } else {
                p.continuation.resume(throwing: CommandError(code: "E_NO_ACK", help: "That didn't reach your box. Try again."))
            }
        }
    }
}

/// What the app keeps of a house between launches: enough to paint the
/// first frame honestly, with its age.
public struct CachedSnapshot: Codable, Equatable, Sendable {
    public var siteId: String
    /// Wall clock when it was written.
    public var savedAtMs: Double
    public var uptimeMs: Double
    public var controlRev: UInt64
    public var fields: [Int: Double]
    public var sources: [String: Source]
    public var dispatchBlockedBy: [String]
    public var dict: [Int: FieldDef]

    public init(siteId: String, savedAtMs: Double, state: SessionState) {
        self.siteId = siteId
        self.savedAtMs = savedAtMs
        uptimeMs = state.uptimeMs
        controlRev = state.controlRev
        fields = state.fields
        sources = state.sources
        dispatchBlockedBy = state.dispatchBlockedBy
        dict = state.dict
    }

    func apply(to s: inout SessionState, includeClock: Bool) {
        if includeClock { s.uptimeMs = uptimeMs }
        s.controlRev = controlRev
        s.fields = fields
        s.sources = sources
        s.dispatchBlockedBy = dispatchBlockedBy
        s.dict = dict
    }
}
