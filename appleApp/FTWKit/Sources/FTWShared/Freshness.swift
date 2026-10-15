import Foundation

/// The freshness band in words: the web app's FreshnessBand.
///
/// Two facts that never collapse into one: how frames reach this phone
/// (`carrier`) and whether the box's own devices are answering
/// (`srcState`). The band claims live only while readings arrive now, and
/// never claims a problem it has not confirmed: connecting while the cache
/// is on screen is normal, not a fault.
public enum Freshness {
    public enum Tone: Sendable { case live, stale, reaching, lost, busy }

    /// How long the band counts a wait in seconds. Past this, a growing
    /// counter only looks broken; the band says it cannot reach the box and
    /// when the last reading was.
    public static let countForMs: Double = 20_000

    public struct Band: Equatable, Sendable {
        public let tone: Tone
        public let message: String
        /// Seconds waited, or the boot percentage. Changes every second.
        public let wait: String?
        /// The age of what is on screen, as its own field. "—" means the box
        /// cannot place the reading at all, which happens after a restart.
        public let age: String?
    }

    public static func band(
        carrier: CarrierKind,
        transport: CarrierKind,
        srcState: SourceState,
        ageMs: Double?,
        phase: SessionPhase,
        waitMs: Double,
        bootPct: Int?,
        noCarrier: Bool,
        busy: Bool = false,
        lastReading: String? = nil
    ) -> Band {
        let reaching = !noCarrier && [.idle, .handshaking, .subscribing, .failed, .booting].contains(phase)
        let connected = carrier.connected
        // The relay turned this phone away because the home already has as
        // many phones watching as it serves. Not a fault, and not ours to fix.
        let turnedAway = busy && !connected && reaching

        // A box that is starting says so for as long as it takes. Anything
        // else that has not connected for a while is said as such.
        let longWait = reaching && !turnedAway && phase != .booting && waitMs >= countForMs
        let tone: Tone = connected ? (srcState == .live ? .live : .stale) : turnedAway ? .busy : (reaching && !longWait ? .reaching : .lost)

        let message: String
        if connected, carrier == .cloud {
            // The box signed every reading; the anchor says how old it is.
            // Without one the copy is never live and its age is unverified.
            switch srcState {
            case .live: message = Words.text("Live via FTW Cloud")
            case .never: message = Words.text("FTW Cloud connected · no reading yet")
            case .down: message = Words.text("FTW Cloud connected · a device stopped responding")
            default: message = ageMs == nil ? Words.text("FTW Cloud · age unverified") : Words.text("FTW Cloud connected · readings")
            }
        } else if connected, carrier == .tunnel {
            // The box's own session, end to end; FTW Cloud only carries it.
            switch srcState {
            case .live: message = Words.text("Live, encrypted via FTW Cloud")
            case .never: message = Words.text("Encrypted via FTW Cloud · no reading yet")
            case .down: message = Words.text("Encrypted via FTW Cloud · a device stopped responding")
            default: message = Words.text("Encrypted via FTW Cloud · readings")
            }
        } else if connected {
            let webrtc = carrier == .webrtc
            switch srcState {
            case .live: message = webrtc ? Words.text("Live at home") : Words.text("Live via encrypted relay")
            case .never: message = webrtc ? Words.text("Home link connected · no reading yet") : Words.text("Encrypted relay connected · no reading yet")
            case .down: message = webrtc ? Words.text("Home link connected · a device stopped responding") : Words.text("Encrypted relay connected · a device stopped responding")
            default: message = webrtc ? Words.text("Home link connected · readings") : Words.text("Encrypted relay connected · readings")
            }
        } else if phase == .terminated {
            // The box is reachable; it told this phone to leave.
            message = Words.text("Access ended")
        } else if turnedAway {
            message = Words.text("FTW is busy")
        } else if phase == .booting {
            message = Words.text("Your box is starting")
        } else if longWait {
            message = lastReading.map { Words.format("Can't reach your box · last reading %@", $0) } ?? Words.text("Can't reach your box")
        } else if reaching {
            if phase == .failed {
                message = Words.text("Reconnecting to your box")
            } else if phase == .subscribing {
                message = Words.text("Waiting for live readings")
            } else if phase == .handshaking, transport == .relay {
                message = Words.text("Securing encrypted relay")
            } else if phase == .handshaking, transport == .tunnel {
                message = Words.text("Securing link via FTW Cloud")
            } else if phase == .handshaking, transport == .webrtc {
                message = Words.text("Securing home link")
            } else {
                message = Words.text("Connecting to your box")
            }
        } else {
            message = Words.text("Can't reach your box")
        }

        var wait: String?
        if reaching, !turnedAway, !longWait {
            if phase == .booting, let bootPct {
                wait = "\(bootPct)%"
            } else {
                wait = "\(max(0, Int(waitMs / 1000)))s"
            }
        }

        var age: String?
        if !(connected && (srcState == .live || srcState == .never)) {
            if let ageMs {
                age = ageMs.isFinite ? PowerFormat.age(ageMs) : nil
            } else {
                age = "—"
            }
        }
        return Band(tone: tone, message: message, wait: wait, age: age)
    }
}
