import Foundation
import Observation

/// One offer from a consent page, from the link or the typed code to Face
/// ID (docs/agents.md in srcfl/ftw, The grant offer).
///
/// A link, tapped or opened by the iPhone Camera from the page's QR code,
/// goes straight to review: the owner reads who asks, its host, whether FTW
/// Cloud knows it and what it asks for, and may compare the page's code.
/// Only with neither link nor QR code does the owner type the code, which
/// fetches the offer from FTW Cloud, once. Either way the offer is checked
/// against the pinned offer keys before anything is shown, and refused when
/// it is unsigned, expired, for a home this phone does not have, or support
/// from anyone but Sourceful. Approving checks it again, against the home
/// open at that moment and the clock then, from the signed bytes rather
/// than what was shown.
@Observable
@MainActor
public final class OfferFlow {
    public enum Step: Equatable {
        /// No link: type the code from the page.
        case code
        case checking
        /// The offer, verified, for the owner to choose from.
        case review(GrantOffer)
        case approving(GrantOffer)
        /// Granted: the box's row.
        case done(AgentRow)
        case refused(OfferError)
    }

    public private(set) var step: Step
    /// The code as typed, when there is no link.
    public var typed = ""
    /// Control is a separate switch, off until ticked.
    public var control = false
    /// Setup needs its own explicit choice, even when control is on.
    public var setup = false
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
    /// The offer as signed, checked again when the owner approves.
    @ObservationIgnored private var signed: SignedOffer?
    /// Told of the row once the box granted it.
    @ObservationIgnored public var onDone: (@MainActor (AgentRow) -> Void)?

    public init(link: OfferLink?, lookup: OfferLookup, keys: OfferKeys, wallMs: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.link = link
        self.lookup = lookup
        self.keys = keys
        self.wallMs = wallMs
        step = link == nil ? .code : .checking
    }

    var nowMs: Int64 { Int64(wallMs()) }

    /// The offer, when the flow has one.
    public var offer: GrantOffer? {
        switch step {
        case .review(let o), .approving(let o): return o
        default: return nil
        }
    }

    /// For a link: check its offer and show it, with no code to type.
    public func start(home: String?) async {
        guard let link, step == .checking else { return }
        do {
            present(try SignedOffer(base64url: link.offer), home: home)
        } catch {
            refuse(.malformed)
        }
    }

    /// The code on the page, to compare, for an offer that came by link.
    /// A typed code needs no second look.
    public var pageCode: String? {
        guard link != nil, let offer, !offer.code.isEmpty else { return nil }
        return OfferCode.show(offer.code)
    }

    /// The owner typed the code: fetch the offer it names, once. A second
    /// press while the first is out asks nothing: the code works once.
    public func submit(home: String?) async {
        guard link == nil, step == .code else { return }
        codeHelp = nil
        guard let code = OfferCode.normalize(typed) else {
            codeHelp = AccessWords.offer(.wrongCode)
            return
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
    /// Only before one is shown, so nothing swaps the signed offer under a
    /// review or an approval.
    public func present(_ given: SignedOffer, home: String?) {
        guard step == .code || step == .checking else { return }
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
        // The box's word on how long it takes, if the page has not read it.
        if !access.keysKnown { await access.refresh() }
        if let row = await access.approve(offer, grant: grant(offer, boxMs: access.boxLongestMs(offer.role))) {
            step = .done(row)
            onDone?(row)
        } else {
            step = .review(offer)
        }
    }

    /// What the owner has chosen so far, within what the box takes.
    public func grant(_ offer: GrantOffer, boxMs: Int64? = nil) -> Grant {
        Grant.from(offer, control: control, lengthMs: lengthMs, boxMs: boxMs, setup: setup)
    }

    /// The lengths to pick from, within the offer and what the box takes.
    public func lengths(boxMs: Int64?) -> [Int64] {
        guard let offer else { return [] }
        return Grant.lengths(role: offer.role, offeredS: offer.ttlS, boxMs: boxMs)
    }

    func check(_ signed: SignedOffer, home: String?) throws -> GrantOffer {
        let offer = try signed.open(keys: keys, nowMs: nowMs)
        // FTW Cloud leaves the home empty and the owner picks it. One that
        // names a home must name this one.
        if !offer.home.isEmpty, offer.home != home { throw OfferError.unknownHome }
        return offer
    }

    private func review(_ offer: GrantOffer) {
        lengthMs = Grant.startLength(role: offer.role, in: Grant.lengths(role: offer.role, offeredS: offer.ttlS))
        control = false
        setup = false
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
