import Foundation
import Observation

/// The spare key on the Box screen: whether Sourceful holds a sealed copy of
/// this home. Written as the web app does it: mark the home, seal the set,
/// and put the mark back when the seal did not land, so the switch never
/// says something the escrow does not hold.
@Observable
@MainActor
public final class SealedCopyModel {
    public enum Stage: Sendable { case idle, working, failed }

    public private(set) var kept: Bool
    public private(set) var stage: Stage = .idle
    /// A sentence, when the last try did not work.
    public private(set) var problem: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let siteId: String

    init(app: AppModel, siteId: String) {
        self.app = app
        self.siteId = siteId
        kept = app.sites.get(siteId)?.escrow == true
    }

    /// Read the mark again. Pairing seals its copy in the background, so the
    /// answer can land after this model was made.
    public func reload() {
        guard stage != .working else { return }
        kept = app.sites.get(siteId)?.escrow == true
    }

    public func set(_ on: Bool) async {
        guard stage != .working else { return }
        stage = .working
        problem = nil
        app.escrow.mark(siteId, on)
        do {
            let wrapping = try await app.vault.unlockWrappingKey(app.passkeys)
            let outcome = await app.escrow.save(wrapping)
            if outcome == .saved || outcome == .cleared {
                kept = on
                stage = .idle
                return
            }
            app.escrow.mark(siteId, !on)
            stage = .failed
            switch outcome {
            case .unsupported: problem = "This phone has no passkey that can seal a copy. Everything else works exactly as it does now."
            case .unreachable: problem = "That didn't reach Sourceful. Your home works either way. Try again when you're back online."
            default: problem = "That didn't work. Your home works either way. Try again."
            }
        } catch is PasskeyCancelled {
            // A dismissed sheet is an answer, not a fault.
            app.escrow.mark(siteId, !on)
            stage = .idle
        } catch {
            app.escrow.mark(siteId, !on)
            stage = .failed
            problem = "That didn't work. Try again."
        }
    }
}
