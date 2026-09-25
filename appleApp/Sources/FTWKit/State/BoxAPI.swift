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
            throw BoxAPIError(code: "E_BAD_BODY", help: "Your box sent something this app couldn't read.", status: res.status)
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
            throw BoxAPIError(code: "E_NO_ANSWER", help: "Your box didn't answer. Still trying.", status: nil)
        }
    }

    static func codeFromBody(_ body: Bytes) -> String? {
        guard !body.isEmpty, let code = (try? JSON(parsing: body))?["code"]?.string, code.hasPrefix("E_") else { return nil }
        return code
    }

    /// What happens now, for a refusal that never reached a handler.
    public static func refusalHelp(_ code: String, _ args: [String: CBOR] = [:]) -> String {
        switch code {
        case "E_UNKNOWN_OP": return "Your box doesn't have that yet — it may be running older software."
        case "E_UNAVAILABLE":
            return args["reason"]?.string == "busy" ? "Your box is busy with something else. This will fill in shortly." : "Your box can't answer that right now. Still trying."
        case "E_SCOPE_DENIED": return "Only the owner of this home can change that."
        case "E_GRANT_REVOKED": return "Your access to this home was withdrawn by its owner."
        case "E_USE_CMD": return "That has to be done from the controls on the home screen."
        case "E_UNSUPPORTED_MEDIA", "E_WHOLE_DOCUMENT", "E_LOCAL_ONLY": return "That one is only available on your box's own page, from home."
        case "E_RESPONSE_TOO_LARGE": return "That's more than we can send over your connection — narrow the range."
        case "E_NEEDS_STEP_UP": return "Your box needs more proof than this phone can give. Do it on your box."
        default: return "That didn't work. Nothing on your box has changed."
        }
    }

    /// What happens now, for a status a handler answered with.
    public static func statusHelp(_ status: Int, _ code: String?) -> String {
        if code == "E_LAST_OWNER_PROTECTED" { return "Someone has to own this home, so the last owner cannot be removed." }
        switch status {
        case 404: return "That's no longer on your box."
        case 403: return "Your box refused that from this phone."
        case 409: return "Something changed on your box first. Nothing here was applied."
        case 503: return "Your box can't answer that yet. Still trying."
        case 500...: return "Something went wrong on your box. Nothing has changed."
        default: return "Your box couldn't do that."
        }
    }
}

/// One rule for everything a screen asks the box for: ask while the session
/// streams, again every time it comes back, and again after a failure, with
/// a wait that doubles up to a quarter of an hour. A carrier that drops
/// settles every request at once, and nothing else would ever ask again.
@MainActor
public final class LiveAsk {
    static let retryMs: Double = 30_000
    static let ceilingMs: Double = 15 * 60_000

    private unowned let site: SiteModel
    private let want: @MainActor () -> String?
    private let ask: @MainActor () async throws -> Void
    private var asked: String?
    private var tries = 0
    private var waitMs = LiveAsk.retryMs
    private var timer: Cancellable?
    private var generation = 0
    private var token: Int?

    /// `want` names what to ask for; the same name is not asked twice, and
    /// nil means there is nothing to ask. `ask` rejects to be asked again.
    public init(site: SiteModel, want: @escaping @MainActor () -> String?, ask: @escaping @MainActor () async throws -> Void) {
        self.site = site
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

    /// Check whether to ask now. Called on every session change and tick,
    /// and by the owner when what it wants changes.
    public func evaluate() {
        guard token != nil else { return }
        guard site.session.phase == .streaming, let name = want() else {
            // Whatever was asked is unanswered now; the next live moment asks
            // again rather than waiting out a backoff.
            asked = nil
            waitMs = Self.retryMs
            timer?.cancel()
            return
        }
        let key = "\(name) \(tries)"
        if asked == key { return }
        asked = key
        timer?.cancel()
        generation += 1
        let mine = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ask()
                if mine == self.generation { self.waitMs = Self.retryMs }
            } catch {
                guard mine == self.generation else { return }
                self.timer = self.site.scheduler.after(self.waitMs) { [weak self] in
                    self?.tries += 1
                    self?.evaluate()
                }
                self.waitMs = min(self.waitMs * 2, Self.ceilingMs)
            }
        }
    }
}
