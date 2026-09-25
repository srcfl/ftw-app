import Foundation

/// The pairing payload.
///
///     https://app.ftw.energy/p#v2.<box_noise_pub>.<pairing_code>.<lan_hint>.<rendezvous_secret>
///
/// Everything after `#` is a fragment and never sent in a request, so the
/// trust anchor reaches the phone optically and reaches no server on the way.
public struct Enrollment: Equatable, Sendable {
    /// The box's Noise static public key. The trust anchor.
    public var boxStaticPublic: Bytes
    /// Single use. The box refuses it a second time. Never log this.
    public var pairingCode: Bytes
    /// Where the box believes it can be reached on the LAN. May be empty.
    public var lanHint: String
    /// The long-lived secret the rotating relay handle is derived from.
    public var rendezvousSecret: Bytes

    public static let version = "v2"
    public static let host = Origin.appHost
    public static let path = "/p"
    public static let boxKeyBytes = 32
    public static let pairingCodeBytes = 16
    public static let rendezvousSecretBytes = 32
    public static let maxLanHintChars = 64

    public init(boxStaticPublic: Bytes, pairingCode: Bytes, lanHint: String, rendezvousSecret: Bytes) {
        self.boxStaticPublic = boxStaticPublic
        self.pairingCode = pairingCode
        self.lanHint = lanHint
        self.rendezvousSecret = rendezvousSecret
    }
}

/// What the user does next. Never which check failed.
public struct EnrollmentError: Error, Equatable, HelpfulError {
    public let code: String
    public let message: String
    public let help: String

    static let scanAgain = "That code did not read cleanly. Hold the phone steady and scan it again."
    static let wrongCode = "That is not an FTW pairing code. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan the QR shown there."
    static let appTooOld = "This box needs a newer version of the app. Update the app, then scan again."
    static let boxTooOld = "This box needs a software update before it can pair. Update the box, then scan again."
}

/// An error that carries a sentence the person holding the phone can act on.
public protocol HelpfulError: Error {
    var help: String { get }
}

extension Enrollment {
    /// Parse whatever a camera, a paste or a link handed over: a full URL or
    /// just the fragment.
    public static func parse(scanned raw: String) throws -> Enrollment {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "nothing scanned", help: "That code did not scan. Try again.")
        }
        return text.hasPrefix("#") ? try parse(fragment: text) : try parse(url: text)
    }

    public static func parse(url raw: String) throws -> Enrollment {
        guard let components = URLComponents(string: raw), let scheme = components.scheme else {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "not a URL", help: EnrollmentError.wrongCode)
        }
        guard scheme.lowercased() == "https" else {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "scheme \(scheme) is not https", help: EnrollmentError.wrongCode)
        }
        guard components.host?.lowercased() == host, components.port == nil, components.user == nil else {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "host is not FTW", help: EnrollmentError.wrongCode)
        }
        guard components.path == path else {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "path \(components.path) is not \(path)", help: EnrollmentError.wrongCode)
        }
        // The fragment as written, not percent-decoded: every segment is
        // base64url and a decoded one would be a different string.
        guard let hashIndex = raw.firstIndex(of: "#") else {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "no fragment", help: EnrollmentError.wrongCode)
        }
        return try parse(fragment: String(raw[hashIndex...]))
    }

    public static func parse(fragment raw: String) throws -> Enrollment {
        let body = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if body.isEmpty {
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "empty fragment", help: EnrollmentError.wrongCode)
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let v = parts[0]

        // Version before shape, and which side is behind decides the
        // sentence. Telling someone to update the wrong thing is worse than
        // saying nothing.
        if v != version {
            if v.count > 1, v.hasPrefix("v"), let n = Int(v.dropFirst()), v.dropFirst().allSatisfy(\.isNumber) {
                let ours = Int(version.dropFirst())!
                throw EnrollmentError(code: "E_QR_VERSION", message: "payload version \(v)", help: n < ours ? EnrollmentError.boxTooOld : EnrollmentError.appTooOld)
            }
            throw EnrollmentError(code: "E_QR_NOT_FTW", message: "fragment does not start with a version", help: EnrollmentError.wrongCode)
        }
        guard parts.count == 5 else {
            throw EnrollmentError(code: "E_QR_SHAPE", message: "\(parts.count) segments, expected 5", help: EnrollmentError.scanAgain)
        }

        let box = try segment(parts[1])
        let code = try segment(parts[2])
        let hintBytes = try segment(parts[3])
        let secret = try segment(parts[4])

        guard box.count == boxKeyBytes else {
            throw EnrollmentError(code: "E_QR_KEY", message: "box key is \(box.count) bytes", help: EnrollmentError.scanAgain)
        }
        guard code.count == pairingCodeBytes else {
            throw EnrollmentError(code: "E_QR_CODE", message: "pairing code is \(code.count) bytes", help: EnrollmentError.scanAgain)
        }
        // The hint becomes a connection target later, so it is checked here.
        guard let hint = String(bytes: hintBytes, encoding: .utf8),
              hint.count <= maxLanHintChars,
              hint.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw EnrollmentError(code: "E_QR_HINT", message: "lan hint is not a plain address", help: EnrollmentError.scanAgain)
        }
        // Downstream this is HKDF input keying material, and a short secret
        // there is a handle an attacker can enumerate.
        guard secret.count == rendezvousSecretBytes else {
            throw EnrollmentError(code: "E_QR_SECRET", message: "rendezvous secret is \(secret.count) bytes", help: EnrollmentError.scanAgain)
        }
        return Enrollment(boxStaticPublic: box, pairingCode: code, lanHint: hint, rendezvousSecret: secret)
    }

    /// The inverse, for tests and the loopback box.
    public func url() -> String {
        let fragment = [
            Enrollment.version,
            Base64url.encode(boxStaticPublic),
            Base64url.encode(pairingCode),
            Base64url.encode(Array(lanHint.utf8)),
            Base64url.encode(rendezvousSecret),
        ].joined(separator: ".")
        return "https://\(Enrollment.host)\(Enrollment.path)#\(fragment)"
    }

    private static func segment(_ s: String) throws -> Bytes {
        do {
            return try Base64url.decode(s)
        } catch {
            throw EnrollmentError(code: "E_QR_ENCODING", message: "segment is not base64url", help: EnrollmentError.scanAgain)
        }
    }
}
