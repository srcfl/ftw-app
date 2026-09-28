import Foundation
import Observation

/// Pairing, the first thing anyone sees. Two taps: scan, Face ID. Everything
/// that can fail does so before the passkey prompt.
@Observable
@MainActor
public final class PairModel {
    public enum Stage: Equatable, Sendable {
        case intro, scanning, pairing, recovering, choosing, demoing
    }

    public var stage: Stage = .intro
    /// A sentence, when something did not work.
    public private(set) var message: String?
    /// The box a link points at, by the same six characters the Box screen
    /// names a paired box by.
    public private(set) var offeredFingerprint: String?
    public private(set) var recovered: [Escrow.Recovered] = []
    /// This phone already holds a key and a home: something local went
    /// missing, not a stranger arriving.
    public private(set) var known: StoredSite?

    @ObservationIgnored private unowned let app: AppModel

    public init(app: AppModel) {
        self.app = app
        if app.vault.isEnrolled { known = app.sites.all().first }
        if let link = app.offeredLink {
            do {
                offeredFingerprint = SiteList.fingerprint(try Enrollment.parse(scanned: link).boxStaticPublic)
            } catch {
                message = "That link is not an FTW pairing code."
            }
        }
    }

    /// Opening the saved home needs a key and a row, and no problem that
    /// says one of them is broken.
    public var canOpen: Bool { known != nil && app.connectHelp == nil }

    /// Scanned with the camera or pasted: a deliberate act, so it pairs.
    public func pair(_ raw: String) async {
        stage = .pairing
        message = nil
        do {
            let result = try await app.pairing.pair(scanned: raw)
            app.paired(result.site.siteId)
        } catch is PasskeyCancelled {
            // A dismissed sheet is not a fault and gets no error voice.
            stage = .intro
        } catch let e as HelpfulError {
            stage = .intro
            message = e.help
        } catch {
            stage = .intro
            message = "That didn't work. Try scanning again."
        }
    }

    /// Pair with the link that arrived, now that someone said so.
    public func acceptOffer() async {
        guard let link = app.offeredLink else { return }
        await pair(link)
    }

    public func declineOffer() {
        app.offeredLink = nil
        offeredFingerprint = nil
    }

    /// Ask the passkey what Sourceful is holding. Costs a prompt, so it is a
    /// button and never a check on arrival.
    public func recover() async {
        stage = .recovering
        message = nil
        do {
            recovered = try await app.escrow.recover(app.passkeys)
            if recovered.isEmpty {
                stage = .intro
                message = "Nothing was saved for this passkey. Open Settings → FTW app in your box dashboard and scan a new pairing code instead."
                return
            }
            stage = .choosing
        } catch is PasskeyCancelled {
            stage = .intro
        } catch let e as HelpfulError {
            stage = .intro
            message = e.help
        } catch {
            stage = .intro
            message = "That didn't work. Open Settings → FTW app in your box dashboard and scan a new pairing code instead."
        }
    }

    public func adopt(_ home: Escrow.Recovered) {
        stage = .pairing
        do {
            let id = try app.escrow.adopt(home, nowMs: app.scheduler.nowMs)
            app.paired(id)
        } catch let e as HelpfulError {
            stage = .intro
            message = e.help
        } catch {
            stage = .intro
            message = "That didn't work. Try scanning the code instead."
        }
    }

    public func openKnown() {
        guard let known else { return }
        app.paired(known.siteId)
    }

    /// A picture was read and held no pairing code.
    public func noCodeFound() {
        stage = .intro
        message = "There is no FTW pairing code in that picture. Try a closer screenshot of the QR."
    }

    public func tryDemo() {
        stage = .demoing
        app.startDemo()
    }

    public func cancel() {
        stage = .intro
        message = nil
    }

    public func dismiss() {
        app.recovering = false
    }
}
