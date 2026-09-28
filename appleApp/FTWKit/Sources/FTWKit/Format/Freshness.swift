import Foundation

/// The freshness band in words: the web app's FreshnessBand.
///
/// Two facts that never collapse into one: how frames reach this phone
/// (`carrier`) and whether the box's own devices are answering
/// (`srcState`). The band claims live only while readings arrive now, and
/// never claims a problem it has not confirmed: connecting while the cache
/// is on screen is normal, not a fault.
public enum Freshness {
    public enum Tone: Sendable { case live, stale, reaching, lost }

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
        noCarrier: Bool
    ) -> Band {
        let reaching = !noCarrier && [.idle, .handshaking, .subscribing, .failed, .booting].contains(phase)
        let connected = carrier == .relay || carrier == .webrtc

        let tone: Tone = connected ? (srcState == .live ? .live : .stale) : (reaching ? .reaching : .lost)

        let message: String
        if connected {
            let liveWhere = carrier == .webrtc ? "Live at home" : "Live via encrypted relay"
            let link = carrier == .webrtc ? "Home link connected" : "Encrypted relay connected"
            switch srcState {
            case .live: message = liveWhere
            case .never: message = "\(link) · no reading yet"
            case .down: message = "\(link) · a device stopped responding"
            default: message = "\(link) · readings"
            }
        } else if phase == .terminated {
            // The box is reachable; it told this phone to leave.
            message = "Access ended"
        } else if phase == .booting {
            message = "Your box is starting"
        } else if reaching {
            if phase == .failed {
                message = "Reconnecting to your box"
            } else if phase == .subscribing {
                message = "Waiting for live readings"
            } else if phase == .handshaking, transport == .relay {
                message = "Securing encrypted relay"
            } else if phase == .handshaking, transport == .webrtc {
                message = "Securing home link"
            } else {
                message = "Connecting to your box"
            }
        } else {
            message = "Can't reach your box"
        }

        var wait: String?
        if reaching {
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

extension SiteModel {
    /// The band for this home, read the way the web app's shell reads it.
    public func freshness(noCarrier: Bool) -> Freshness.Band {
        Freshness.band(
            carrier: carrier,
            transport: session.carrier,
            srcState: srcState,
            ageMs: ageMs,
            phase: session.phase,
            waitMs: connectionWaitMs,
            bootPct: session.boot?.pct,
            noCarrier: noCarrier
        )
    }
}
