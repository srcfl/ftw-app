import Foundation
import Observation

/// One offer from a consent page, from the link or the typed code to Face
/// ID (docs/agents.md in srcfl/ftw, The grant offer).
///
/// A link someone else sent never reaches Face ID on its own: the owner
/// types the code the page in front of them shows, and it must be the
/// offer's. Typed without a link, the code fetches the offer from FTW Cloud,
/// once. Either way the offer is checked against the pinned offer keys
/// before anything is shown, and refused when it is unsigned, expired, for
/// a home this phone does not have, or support from anyone but Sourceful.
/// Approving checks it again, against the home open at that moment and the
/// clock then, from the signed bytes rather than what was shown.
@Observable
@MainActor
public final class OfferFlow {
    public enum Step: Equatable {
        /// Type the code from the page.
        case code
        case checking
        /// The offer, verified, for the owner to choose from.
        case review(GrantOffer)
        case approving(GrantOffer)
        /// Granted: the box's row.
        case done(AgentRow)
        case refused(OfferError)
    }

    public private(set) var step: Step = .code
    /// The code as typed.
    public var typed = ""
    /// Control is a separate switch, off until ticked.
    public var control = false
    /// FTW Cloud does not know this client: the owner says they started
    /// this and trust its address before Face ID.
    public var trustsUnknown = false
    public var lengthMs: Int64 = 30 * 86_400_000
    /// Why the code did not go through, under the field.
    public private(set) var codeHelp: String?

    public let link: OfferLink?
    @ObservationIgnored let lookup: OfferLookup
    @ObservationIgnored let keys: OfferKeys
    @ObservationIgnored let wallMs: @MainActor () -> Double
    /// Opened before the code: a link's offer is checked at once, so a bad
    /// one is refused without asking for anything.
    @ObservationIgnored private var opened: GrantOffer?
    /// The offer as signed, checked again when the owner approves.
    @ObservationIgnored private var signed: SignedOffer?
    /// Told of the row once the box granted it.
    @ObservationIgnored public var onDone: (@MainActor (AgentRow) -> Void)?

    public init(link: OfferLink?, lookup: OfferLookup, keys: OfferKeys, wallMs: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.link = link
        self.lookup = lookup
        self.keys = keys
        self.wallMs = wallMs
    }

    var nowMs: Int64 { Int64(wallMs()) }

    /// The offer, when the flow has one.
    public var offer: GrantOffer? {
        switch step {
        case .review(let o), .approving(let o): return o
        default: return nil
        }
    }

    /// For a link: check its offer before asking for the code.
    public func start(home: String?) async {
        guard let link, opened == nil, step == .code else { return }
        guard !keys.isEmpty else { return refuse(.noPinnedKey) }
        do {
            let carried = try SignedOffer(base64url: link.offer)
            opened = try check(carried, home: home)
            signed = carried
        } catch let e as OfferError {
            refuse(e)
        } catch {
            refuse(.malformed)
        }
    }

    /// The owner typed the code: compare it with the link's offer, or fetch
    /// the offer it names.
    public func submit(home: String?) async {
        codeHelp = nil
        guard let code = OfferCode.normalize(typed) else {
            codeHelp = AccessWords.offer(.wrongCode)
            return
        }
        if let opened {
            guard OfferCode.matches(code, opened) else {
                codeHelp = AccessWords.offer(.wrongCode)
                return
            }
            return review(opened)
        }
        guard !keys.isEmpty else { return refuse(.noPinnedKey) }
        step = .checking
        do {
            let fetched = try await lookup.byCode(code)
            let offer = try check(fetched, home: home)
            guard OfferCode.matches(code, offer) else { return refuse(.wrongCode) }
            signed = fetched
            review(offer)
        } catch let e as OfferError where e == .notFound {
            step = .code
            codeHelp = AccessWords.offer(e)
        } catch let e as OfferError {
            refuse(e)
        } catch {
            refuse(.malformed)
        }
    }

    /// An offer that came another way, such as Get help: checked like any.
    public func present(_ given: SignedOffer, home: String?) {
        do {
            let offer = try check(given, home: home)
            signed = given
            review(offer)
        } catch let e as OfferError {
            refuse(e)
        } catch {
            refuse(.malformed)
        }
    }

    /// Grant what the owner chose, behind Face ID, at the home open now.
    /// The signed offer is checked again first: the home may have changed
    /// and the clock moved since it was shown.
    public func approve(_ access: AccessModel, home: String?) async {
        guard case .review(let shown) = step, let signed else { return }
        guard shown.verified || trustsUnknown else { return }
        let offer: GrantOffer
        do {
            offer = try check(signed, home: home)
        } catch let e as OfferError {
            return refuse(e)
        } catch {
            return refuse(.malformed)
        }
        guard offer == shown else { return refuse(.malformed) }
        step = .approving(offer)
        if let row = await access.approve(offer, grant: grant(offer)) {
            step = .done(row)
            onDone?(row)
        } else {
            step = .review(offer)
        }
    }

    /// What the owner has chosen so far.
    public func grant(_ offer: GrantOffer) -> Grant {
        Grant.from(offer, control: control, lengthMs: lengthMs)
    }

    public var lengths: [Int64] {
        guard let offer else { return [] }
        return Grant.lengths(role: offer.role, offeredS: offer.ttlS)
    }

    func check(_ signed: SignedOffer, home: String?) throws -> GrantOffer {
        let offer = try signed.open(keys: keys, nowMs: nowMs)
        // FTW Cloud leaves the home empty and the owner picks it. One that
        // names a home must name this one.
        if !offer.home.isEmpty, offer.home != home { throw OfferError.unknownHome }
        return offer
    }

    private func review(_ offer: GrantOffer) {
        let picks = Grant.lengths(role: offer.role, offeredS: offer.ttlS)
        lengthMs = picks.last ?? lengthMs
        if offer.isSupport, let week = picks.last(where: { $0 <= 7 * 86_400_000 }) { lengthMs = week }
        control = false
        trustsUnknown = false
        step = .review(offer)
    }

    private func refuse(_ e: OfferError) {
        step = .refused(e)
    }
}

/// Where Get help gets a support offer: Sourceful's help desk opens a
/// ticket and FTW Cloud's support tooling signs an offer for it, with the
/// ticket id and the support key FTW Cloud's keys part made. There is no
/// desk yet: a release build has `NoSupportDesk`, and the simulated home
/// has one of its own.
@MainActor
public protocol SupportDesk: AnyObject {
    /// Whether a ticket can be opened from the app.
    var isOpen: Bool { get }
    /// Opens a ticket for what the owner wrote, which goes to the desk,
    /// and returns Sourceful's signed offer for it.
    func open(problem: String) async throws -> SignedOffer
}

/// No help desk behind the app yet. Get help says so.
@MainActor
public final class NoSupportDesk: SupportDesk {
    public init() {}
    public var isOpen: Bool { false }
    public func open(problem: String) async throws -> SignedOffer { throw OfferError.unreachable }
}

/// What the owner wrote for each ticket. The help desk has the words; this
/// phone keeps a copy beside the ticket id, and the box never sees them.
public struct TicketNote: Codable, Equatable, Sendable {
    public var ticket: String
    public var problem: String
    public var atMs: Double

    public init(ticket: String, problem: String, atMs: Double) {
        self.ticket = ticket
        self.problem = problem
        self.atMs = atMs
    }
}

/// Where a client lives and what it asked for, as the offer the owner
/// approved on this phone said, by its row's id: so control can be turned
/// on later with what the client asked, never more.
public struct ClientNote: Codable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var verified: Bool
    public var askedOps: [String]
    public var askedCaps: Caps

    public init(id: String, host: String, verified: Bool, askedOps: [String] = [], askedCaps: Caps = Caps()) {
        self.id = id
        self.host = host
        self.verified = verified
        self.askedOps = askedOps
        self.askedCaps = askedCaps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        host = try c.decode(String.self, forKey: .host)
        verified = try c.decode(Bool.self, forKey: .verified)
        askedOps = try c.decodeIfPresent([String].self, forKey: .askedOps) ?? []
        askedCaps = try c.decodeIfPresent(Caps.self, forKey: .askedCaps) ?? Caps()
    }
}
