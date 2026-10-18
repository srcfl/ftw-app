import Foundation
import Network

/// A short code is exchanged directly with the box on the home network.
/// Its full enrollment link then follows the same path as a camera scan.
public struct LocalPairing: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send

    public init(send: @escaping Send = LocalPairing.request) { self.send = send }

    public func redeem(address: String, code: String, password: String = "") async throws -> String {
        let input = try Self.input(address: address, code: code)
        var request = URLRequest(url: input.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !password.isEmpty { request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Claim(kind: "claim", code: input.code))
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalPairingError.unreachable }
        if response.statusCode == 401 { throw LocalPairingError.password }
        guard response.statusCode == 200 else {
            throw response.statusCode == 400 ? LocalPairingError.code : LocalPairingError.unavailable
        }
        guard data.count < 8_192, let reply = try? JSONDecoder().decode(Reply.self, from: data),
              (try? Enrollment.parse(scanned: reply.url)) != nil else { throw LocalPairingError.unavailable }
        return reply.url
    }

    /// Copying the code on the box includes its address as a fragment. The
    /// code never becomes a URL path or query, including while it is pasted.
    static func input(address: String, code: String) throws -> (url: URL, code: String) {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pasted = URLComponents(string: typed), pasted.scheme != nil, let fragment = pasted.fragment {
            var box = pasted
            box.fragment = nil
            host = box.string ?? ""
            typed = fragment
        }
        let canonical = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        guard canonical.count == 8, canonical.allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }) else {
            throw LocalPairingError.code
        }
        if !host.contains("://") { host = "http://" + host }
        guard var target = URLComponents(string: host),
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              let hostname = target.host, Self.localHost(hostname),
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil,
              target.path.isEmpty || target.path == "/",
              target.port == nil || (1...65535).contains(target.port!) else { throw LocalPairingError.address }
        target.path = "/api/app-link/pairing"
        guard let url = target.url else { throw LocalPairingError.address }
        return (url, canonical)
    }

    private static func localHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") || name.hasSuffix(".home.arpa") { return true }
        if let address = IPv4Address(name) {
            let b = Array(address.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        if let address = IPv6Address(name) {
            let b = Array(address.rawValue)
            return address == .loopback || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
        }
        return false
    }

    public static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoPairingRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalPairingError.unavailable }
        return (data, http)
    }

    private struct Claim: Encodable { let kind: String; let code: String }
    private struct Reply: Decodable { let url: String }
}

private final class NoPairingRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum LocalPairingError: Error, HelpfulError, Equatable {
    case address, code, password, unreachable, unavailable

    public var help: String {
        let english = switch self {
        case .address: "Enter the box address shown beside the pairing code, for example ftw.local:8080."
        case .code: "That code has expired, was used or is incorrect. Make a new pairing code in Settings → FTW app."
        case .password: "Enter the house password you use in the box's dashboard."
        case .unreachable: "Could not reach the box. Stay on your home Wi-Fi, check its address and allow Local Network access for FTW in iPhone Settings."
        case .unavailable: "Could not pair with a code. Update the box, make a new code and try again, or use a picture of its QR."
        }
        return NodeWords.text(english)
    }
}
