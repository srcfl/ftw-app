import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A WebSocket over URLSession, feeding events back on the main actor.
///
/// Every event carries a generation check through `closed`, so a socket
/// that has been dropped can never deliver a late frame to its successor.
@MainActor
public final class URLSessionWebSocket: NSObject, WebSocketConnection {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let events: WebSocketEvents
    private var closed = false
    private var opened = false

    public static func factory() -> WebSocketFactory {
        { url, events in URLSessionWebSocket(url: url, events: events) }
    }

    init(url: URL, events: WebSocketEvents) {
        self.events = events
        super.init()
        let delegate = Delegate(owner: self)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        receive()
    }

    public func send(_ data: Bytes) {
        guard !closed, let task else { return }
        task.send(.data(Data(data))) { _ in }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch result {
                case .success(let message):
                    if !self.opened { self.didOpen() }
                    switch message {
                    case .string(let text): self.events.onText(text)
                    case .data(let data): self.events.onBinary(data.byteArray)
                    @unknown default: break
                    }
                    self.receive()
                case .failure:
                    // The close handshake arrives through the delegate with its
                    // code and reason, and the relay's codes matter: 4409 and
                    // 4410 carry the epoch. The delegate may land a moment after
                    // this failure, so it gets that moment before a plain 1006.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let code = task.closeCode.rawValue
                    let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.didClose(code: code == 0 ? 1006 : code, reason: reason)
                }
            }
        }
    }

    fileprivate func didOpen() {
        guard !closed, !opened else { return }
        opened = true
        events.onOpen()
    }

    fileprivate func didClose(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        task = nil
        session = nil
        events.onClose(code, reason)
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: URLSessionWebSocket?

        init(owner: URLSessionWebSocket) {
            self.owner = owner
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            Task { @MainActor [weak owner] in owner?.didOpen() }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor [weak owner] in owner?.didClose(code: closeCode.rawValue, reason: text) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            Task { @MainActor [weak owner] in owner?.didClose(code: 1006, reason: "") }
        }
    }
}
