#if os(Linux)
import Foundation
import Glibc
@testable import FTWKit

/// A minimal RFC 6455 client over a plain TCP socket, for the live test on
/// Linux only: Foundation there is built on a libcurl without WebSocket
/// support, where Apple platforms have URLSessionWebSocketTask. It talks to
/// a local bridge that carries the frames to the relay unchanged.
@MainActor
final class PlainWebSocket: WebSocketConnection {
    private enum Event: Sendable {
        case open
        case text(String)
        case binary([UInt8])
        case close(Int, String)
    }

    private let fd: Int32
    private var closed = false

    static func factory() -> WebSocketFactory {
        { url, events in PlainWebSocket(url: url, events: events) }
    }

    init(url: URL, events: WebSocketEvents) {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        let host = url.host ?? "127.0.0.1"
        let port = UInt16(url.port ?? 80)
        let path = url.path.isEmpty ? "/" : url.path
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let fd = self.fd

        // One consumer on the main actor, so events arrive in order.
        Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !self.closed || { if case .close = event { return true }; return false }() else { continue }
                switch event {
                case .open: events.onOpen()
                case .text(let t): events.onText(t)
                case .binary(let b): events.onBinary(b)
                case .close(let code, let reason):
                    self.closed = true
                    events.onClose(code, reason)
                }
            }
        }

        Thread.detachNewThread {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else {
                continuation.yield(.close(1006, ""))
                continuation.finish()
                return
            }
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            PlainWebSocket.write(fd, Array(request.utf8))

            var buffer = [UInt8]()
            func fill(_ n: Int) -> Bool {
                var chunk = [UInt8](repeating: 0, count: 65_536)
                while buffer.count < n {
                    let got = recv(fd, &chunk, chunk.count, 0)
                    if got <= 0 { return false }
                    buffer += chunk[0..<got]
                }
                return true
            }
            // The upgrade response.
            while true {
                if let end = buffer.firstRange(of: [13, 10, 13, 10]) {
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<end.upperBound)
                    guard head.hasPrefix("HTTP/1.1 101") else {
                        continuation.yield(.close(1006, ""))
                        continuation.finish()
                        return
                    }
                    break
                }
                if !fill(buffer.count + 1) {
                    continuation.yield(.close(1006, ""))
                    continuation.finish()
                    return
                }
            }
            continuation.yield(.open)

            var message = [UInt8]()
            var messageOpcode: UInt8 = 0
            while true {
                guard fill(2) else { break }
                let fin = buffer[0] & 0x80 != 0
                let opcode = buffer[0] & 0x0f
                var len = Int(buffer[1] & 0x7f)
                var at = 2
                if len == 126 {
                    guard fill(4) else { break }
                    len = Int(buffer[2]) << 8 | Int(buffer[3])
                    at = 4
                } else if len == 127 {
                    guard fill(10) else { break }
                    len = buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }
                    at = 10
                }
                guard fill(at + len) else { break }
                let payload = Array(buffer[at..<at + len])
                buffer.removeSubrange(0..<at + len)
                switch opcode {
                case 0x8:
                    let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : 1005
                    let reason = payload.count > 2 ? String(decoding: payload[2...], as: UTF8.self) : ""
                    continuation.yield(.close(code, reason))
                    continuation.finish()
                    Glibc.close(fd)
                    return
                case 0x9:
                    PlainWebSocket.write(fd, PlainWebSocket.frame(opcode: 0xA, payload))
                case 0x0, 0x1, 0x2:
                    if opcode != 0 { messageOpcode = opcode; message = [] }
                    message += payload
                    if fin {
                        continuation.yield(messageOpcode == 1 ? .text(String(decoding: message, as: UTF8.self)) : .binary(message))
                        message = []
                    }
                default:
                    break
                }
            }
            continuation.yield(.close(1006, ""))
            continuation.finish()
        }
    }

    nonisolated static func frame(opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(0x80 | UInt8(payload.count))
        } else if payload.count < 65_536 {
            out.append(0x80 | 126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xff))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: payload.count >> shift)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out += mask
        for (i, b) in payload.enumerated() { out.append(b ^ mask[i % 4]) }
        return out
    }

    nonisolated static func write(_ fd: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n <= 0 { return }
            sent += n
        }
    }

    func send(_ data: Bytes) {
        guard !closed else { return }
        PlainWebSocket.write(fd, Self.frame(opcode: 0x2, data))
    }

    func close() {
        guard !closed else { return }
        closed = true
        PlainWebSocket.write(fd, Self.frame(opcode: 0x8, [0x03, 0xe8]))
        shutdown(fd, Int32(SHUT_RDWR))
    }
}
#endif
