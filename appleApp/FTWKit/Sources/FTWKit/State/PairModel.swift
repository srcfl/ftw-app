import Foundation
import Observation

/// Pairing, the first thing anyone sees. Two taps: scan, Face ID. Everything
/// that can fail does so before the passkey prompt.
@Observable
@MainActor
public final class PairModel {
    public enum Stage: Equatable, Sendable {
        case intro, scanning, enteringCode, pairing, demoing
    }

    public var stage: Stage = .intro
    /// A sentence, when something did not work.
    public private(set) var message: String?
    /// The box a link points at, by the same six characters the Box screen
    /// names a paired box by.
    public private(set) var offeredFingerprint: String?
    /// This phone already holds a key and a home: something local went
    /// missing, not a stranger arriving.
    public private(set) var known: StoredSite?
    public var boxAddress = "ftw.local:8080"
    public var code = ""
    public var password = ""
    public private(set) var needsPassword = false
    public private(set) var codeBusy = false

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var codeAttempt = 0

    public init(app: AppModel) {
        self.app = app
        if app.vault.isEnrolled { known = app.sites.all().first }
        if let link = app.offeredLink {
            do {
                offeredFingerprint = SiteList.fingerprint(try Enrollment.parse(scanned: link).boxStaticPublic)
            } catch {
                message = NodeWords.text("That link is not an FTW pairing code.")
            }
        }
    }

    /// Opening the saved home needs a key and a row, and no problem that
    /// says one of them is broken.
    public var canOpen: Bool { known != nil && app.connectHelp == nil }

    /// Scanned with the camera or pasted: a deliberate act, so it pairs.
    /// An assistant's consent page goes where its link goes.
    public func pair(_ raw: String) async {
        if OfferLink(raw) != nil { return scannedOffer(raw) }
        stage = .pairing
        message = nil
        do {
            let site = try await app.pairing.pair(scanned: raw)
            app.paired(site.siteId)
        } catch is PasskeyCancelled {
            // A dismissed sheet is not a fault and gets no error voice.
            stage = .intro
        } catch let e as HelpfulError {
            stage = .intro
            message = e.help
        } catch {
            stage = .intro
            message = NodeWords.text("That didn't work. Try scanning again.")
        }
    }

    /// An assistant's consent QR in the pairing scanner, taken as its link:
    /// the home this phone opens shows the offer, or keeps it until it can
    /// open. With no home there is nothing to grant from.
    private func scannedOffer(_ raw: String) {
        stage = .intro
        guard app.vault.isEnrolled, let home = app.sites.current() else {
            message = NodeWords.text("That is an assistant's QR code. Connect your box first, then scan it with the iPhone Camera.")
            return
        }
        app.offer(raw)
        if app.connectHelp == nil {
            app.paired(home.siteId)
        } else {
            message = NodeWords.text("The assistant's request opens once your home does.")
        }
    }

    /// Pair with the link that arrived, now that someone said so.
    public func acceptOffer() async {
        guard let link = app.offeredLink else { return }
        await pair(link)
    }

    public func enterCode() {
        message = nil
        stage = .enteringCode
    }

    public func connectCode(using local: LocalPairing = LocalPairing()) async {
        guard !codeBusy else { return }
        codeAttempt += 1
        let attempt = codeAttempt
        codeBusy = true
        defer {
            if attempt == codeAttempt {
                codeBusy = false
                password = ""
            }
        }
        message = nil
        do {
            let link: String
            if (try? Enrollment.parse(scanned: code)) != nil {
                link = code
            } else {
                link = try await local.redeem(address: boxAddress, code: code, password: password)
            }
            guard attempt == codeAttempt, !Task.isCancelled else { return }
            codeBusy = false
            password = ""
            await pair(link)
        } catch {
            guard attempt == codeAttempt, !Task.isCancelled else { return }
            codeBusy = false
            password = ""
            needsPassword = (error as? LocalPairingError) == .password
            message = (error as? HelpfulError)?.help ?? LocalPairingError.unreachable.help
        }
    }

    public func declineOffer() {
        app.offeredLink = nil
        offeredFingerprint = nil
    }

    public func openKnown() {
        guard let known else { return }
        app.paired(known.siteId)
    }

    /// A picture was read and held no pairing code.
    public func noCodeFound() {
        stage = .intro
        message = NodeWords.text("There is no FTW pairing code in that picture. Try a closer screenshot of the QR.")
    }

    public func tryDemo() {
        stage = .demoing
        app.startDemo()
    }

    public func cancel() {
        codeAttempt += 1
        codeBusy = false
        password = ""
        stage = .intro
        message = nil
    }

    public func dismiss() {
        app.recovering = false
    }
}
