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

    /// For a link: fetch its offer if it does not carry one, and check it
    /// before asking for the code.
    public func start(home: String?) async {
        guard let link else { return }
        guard !keys.isEmpty else { return refuse(.noPinnedKey) }
        step = .checking
        do {
            let signed: SignedOffer
            if let carried = link.offer {
                signed = try SignedOffer(base64url: carried)
            } else {
                signed = try await lookup.byRequest(link.request)
            }
            opened = try check(signed, home: home)
            step = .code
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
            let offer = try check(try await lookup.byCode(code), home: home)
            guard OfferCode.matches(code, offer) else { return refuse(.wrongCode) }
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
    public func present(_ signed: SignedOffer, home: String?) {
        do {
            review(try check(signed, home: home))
        } catch let e as OfferError {
            refuse(e)
        } catch {
            refuse(.malformed)
        }
    }

    /// Grant what the owner chose, behind Face ID, at this home.
    public func approve(_ access: AccessModel) async {
        guard case .review(let offer) = step else { return }
        step = .approving(offer)
        if let row = await access.approve(offer, grant: grant(offer)) {
            step = .done(row)
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
    func open(problem: String, control: Bool) async throws -> SignedOffer
}

/// No help desk behind the app yet. Get help says so.
@MainActor
public final class NoSupportDesk: SupportDesk {
    public init() {}
    public var isOpen: Bool { false }
    public func open(problem: String, control: Bool) async throws -> SignedOffer { throw OfferError.unreachable }
}

/// What the owner wrote for each ticket, kept on this phone only: the box
/// keeps the ticket id, never the words.
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

/// Where a client lives, as the offer the owner approved on this phone
/// said, by its row's id.
public struct ClientNote: Codable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var verified: Bool

    public init(id: String, host: String, verified: Bool) {
        self.id = id
        self.host = host
        self.verified = verified
    }
}
