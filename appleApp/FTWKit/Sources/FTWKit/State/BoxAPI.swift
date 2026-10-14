import Foundation

/// Something a screen can put in front of a person. `code` is kept for the
/// few callers that branch on it; no caller renders it.
public struct BoxAPIError: Error, Equatable, HelpfulError {
    public let code: String
    public let help: String
    /// The HTTP status when a handler answered. Nil when none ran.
    public let status: Int?
}

extension SiteModel {
    /// Call the box's own API and get JSON back, with sentences.
    ///
    /// It runs the step-up: a write refused with E_NEEDS_STEP_UP is asked
    /// again once, after the passkey ceremony, and never with the flag
    /// before one has run. The box prices each route; this app carries no
    /// list of them.
    public func callBox(_ method: APIMethod, _ path: String, query: [String: String] = [:], body: JSON? = nil) async throws -> JSON? {
        let res = try await sendBox(method, path, query: query, body: body, stepUp: false)
        guard (200..<300).contains(res.status) else {
            let code = Self.codeFromBody(res.body)
            throw BoxAPIError(code: code ?? "HTTP_\(res.status)", help: Self.statusHelp(res.status, code), status: res.status)
        }
        if res.body.isEmpty { return nil }
        do {
            return try JSON(parsing: res.body)
        } catch {
            throw BoxAPIError(code: "E_BAD_BODY", help: AppWords.text("Your box sent something this app couldn't read."), status: res.status)
        }
    }

    private func sendBox(_ method: APIMethod, _ path: String, query: [String: String], body: JSON?, stepUp: Bool) async throws -> APIResponse {
        do {
            return try await api(APIRequest(method: method, path: path, query: query, body: body?.encoded(), stepUp: stepUp))
        } catch let refusal as BoxRefusal {
            let code = refusal.detail.code
            // The one place a step-up runs, and only once. A second refusal
            // after a ceremony is the box saying something else.
            if code == "E_NEEDS_STEP_UP", !stepUp {
                let outcome = await self.stepUp?() ?? .unavailable
                guard outcome == .done else {
                    throw BoxAPIError(code: code, help: outcome.help ?? "", status: nil)
                }
                return try await sendBox(method, path, query: query, body: body, stepUp: true)
            }
            throw BoxAPIError(code: code, help: Self.refusalHelp(code, refusal.detail.args), status: nil)
        } catch {
            // No code and no status: the wire went away or the deadline
            // passed. Both heal on their own.
            throw BoxAPIError(code: "E_NO_ANSWER", help: AppWords.text("Your box didn't answer. Still trying."), status: nil)
        }
    }

    static func codeFromBody(_ body: Bytes) -> String? {
        guard !body.isEmpty, let code = (try? JSON(parsing: body))?["code"]?.string, code.hasPrefix("E_") else { return nil }
        return code
    }

    /// What happens now, for a refusal that never reached a handler.
    public static func refusalHelp(_ code: String, _ args: [String: CBOR] = [:]) -> String {
        switch code {
        case "E_UNKNOWN_OP": return AppWords.text("Your box doesn't have that yet — it may be running older software.")
        case "E_UNAVAILABLE":
            return AppWords.text(args["reason"]?.string == "busy" ? "Your box is busy with something else. This will fill in shortly." : "Your box can't answer that right now. Still trying.")
        case "E_SCOPE_DENIED": return AppWords.text("Only the owner of this home can change that.")
        case "E_GRANT_REVOKED": return AppWords.text("Your access to this home was withdrawn by its owner.")
        case "E_USE_CMD": return AppWords.text("That has to be done from the controls on the home screen.")
        case "E_UNSUPPORTED_MEDIA", "E_WHOLE_DOCUMENT", "E_LOCAL_ONLY": return AppWords.text("That one is only available on your box's own page, from home.")
        case "E_RESPONSE_TOO_LARGE": return AppWords.text("That's more than we can send over your connection — narrow the range.")
        case "E_NEEDS_STEP_UP": return AppWords.text("Your box needs more proof than this phone can give. Do it on your box.")
        default: return AppWords.text("That didn't work. Nothing on your box has changed.")
        }
    }

    /// What happens now, for a status a handler answered with.
    public static func statusHelp(_ status: Int, _ code: String?) -> String {
        if code == "E_LAST_OWNER_PROTECTED" { return AppWords.text("Someone has to own this home, so the last owner cannot be removed.") }
        switch status {
        case 404: return AppWords.text("That's no longer on your box.")
        case 403: return AppWords.text("Your box refused that from this phone.")
        case 409: return AppWords.text("Something changed on your box first. Nothing here was applied.")
        case 503: return AppWords.text("Your box can't answer that yet. Still trying.")
        case 500...: return AppWords.text("Something went wrong on your box. Nothing has changed.")
        default: return AppWords.text("Your box couldn't do that.")
        }
    }
}

/// One rule for everything a screen asks the box for. `want` names the
/// data by its age: the five minutes for history, the quarter for the
/// plan, the day for prices. An answer stands while that name holds. When
/// someone starts looking again (a view appears, or the stream comes back)
/// an answer older than `ttlMs` no longer stands. Neither a view appearing
/// nor a redial asks by itself, and no timer does: an answer from before
/// the app went to the background still stands when it comes back.
///
/// An answer a dropped carrier never gave is asked for at the next live
/// moment. A failure is asked again after a wait that doubles up to a
/// quarter of an hour. Reads that wait for the box's one API slot go in
/// `order`.
@MainActor
public final class LiveAsk {
    static let retryMs: Double = 30_000
    static let ceilingMs: Double = 15 * 60_000

    private unowned let site: SiteModel
    private let order: ReadOrder
    private let ttlMs: Double
    private let want: @MainActor () -> String?
    private let ask: @MainActor () async throws -> Void
    /// The last answer, by name, and when it came.
    private var answered: (name: String, atMs: Double)?
    /// What is on the wire now.
    private var asking: String?
    /// What failed, waiting out its backoff.
    private var failed: String?
    /// Whether someone looked at the last evaluation, while it streamed.
    private var looking = false
    private var waitMs = LiveAsk.retryMs
    private var timer: Cancellable?
    private var generation = 0
    private var token: Int?

    /// `want` names what to ask for, or nil when nobody looks. `ask`
    /// rejects to be asked again.
    public init(site: SiteModel, order: ReadOrder = .later, ttlMs: Double = .infinity, want: @escaping @MainActor () -> String?, ask: @escaping @MainActor () async throws -> Void) {
        self.site = site
        self.order = order
        self.ttlMs = ttlMs
        self.want = want
        self.ask = ask
        token = site.observe { [weak self] in self?.evaluate() }
    }

    public func stop() {
        generation += 1
        timer?.cancel()
        if let token { site.unobserve(token) }
        token = nil
    }

    /// Check whether to ask now. Called on every session change and clock
    /// tick, and by the owner when what it wants changes.
    public func evaluate() {
        guard token != nil else { return }
        guard site.session.phase == .streaming else {
            // What was on the wire is settled with the carrier. The next
            // live moment asks again at once rather than waiting out a
            // backoff; an answer already given still stands.
            generation += 1
            asking = nil
            failed = nil
            waitMs = Self.retryMs
            timer?.cancel()
            looking = false
            return
        }
        guard let name = want() else {
            // Nobody looks: no retry. What is on the wire may still land.
            failed = nil
            timer?.cancel()
            looking = false
            return
        }
        if !looking {
            looking = true
            if let answered, site.scheduler.nowMs - answered.atMs >= ttlMs { self.answered = nil }
        }
        if asking == name || failed == name || answered?.name == name { return }
        start(name)
    }

    private func start(_ name: String) {
        timer?.cancel()
        failed = nil
        asking = name
        generation += 1
        let mine = generation
        let order = order
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await ReadOrder.$current.withValue(order) { try await self.ask() }
                guard mine == self.generation else { return }
                self.asking = nil
                self.answered = (name, self.site.scheduler.nowMs)
                self.waitMs = Self.retryMs
            } catch {
                guard mine == self.generation else { return }
                self.asking = nil
                self.failed = name
                self.timer = self.site.scheduler.after(self.waitMs) { [weak self] in
                    self?.failed = nil
                    self?.evaluate()
                }
                self.waitMs = min(self.waitMs * 2, Self.ceilingMs)
            }
        }
    }
}
