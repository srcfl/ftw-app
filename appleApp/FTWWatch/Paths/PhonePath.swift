import FTWShared
import os
import WatchConnectivity

/// Both paths through the iPhone, over WatchConnectivity. The phone hands
/// over its records after each write of its cache, sends Now's frames
/// while the watch looks, and runs each command over its own session with
/// the box. The watch gives the phone its public key, so the phone can add
/// it to the box and the watch can also go through FTW Cloud on its own
/// (`CloudPath`).
@MainActor
final class PhonePath: NSObject, ReadPath, CommandPath {
    nonisolated static let log = Logger(subsystem: "energy.ftw.app.watchkitapp", category: "phone")

    private var sink: PathSink?
    private var looking = false
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start(_ sink: @escaping PathSink) {
        self.sink = sink
        guard let session else { return sink(.canSend(false)) }
        session.delegate = self
        session.activate()
    }

    func look() {
        looking = true
        ask(.look)
    }

    func away() {
        looking = false
        ask(.away)
    }

    private func ask(_ a: WatchAsk) {
        guard let session, session.activationState == .activated, session.isReachable, let data = try? a.data() else { return }
        // WatchConnectivity calls back on its own queue, never the main one.
        session.sendMessageData(data, replyHandler: nil) { @Sendable error in
            PhonePath.log.notice("ask not delivered: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The phone answers at once that it has the command; the box's steps
    /// follow as news. A send that fails never reached the box.
    func send(_ command: WatchCommand) {
        guard let session, session.activationState == .activated, session.isReachable, let data = try? WatchAsk.command(command).data() else {
            sink?(.notSent(commandID: command.id))
            return
        }
        session.sendMessageData(data, replyHandler: { @Sendable [weak self] reply in
            guard let news = WatchNews.from(reply) else { return }
            Task { @MainActor in self?.sink?(.news(news)) }
        }, errorHandler: { @Sendable [weak self] error in
            PhonePath.log.notice("command not delivered: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self?.sink?(.notSent(commandID: command.id)) }
        })
    }

    private func deliver(_ event: PathEvent) {
        sink?(event)
    }

    /// The watch's public key, for the phone to add this watch to its box.
    /// WatchConnectivity keeps the newest and hands it over when the phone
    /// next wakes.
    private func offerKey() {
        guard let session, session.activationState == .activated, let key = WatchIdentity.publicKey() else { return }
        do {
            try session.updateApplicationContext([WatchLink.watchKeyKey: key])
        } catch {
            PhonePath.log.notice("key not offered: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension PhonePath: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { PhonePath.log.error("session: \(error.localizedDescription, privacy: .public)") }
        // The phone's newest context, if it sent one while this app slept.
        let data = session.receivedApplicationContext[WatchContext.key] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.deliver(.canSend(reachable))
            if let data, let ctx = WatchContext.unpacked(data) { self.deliver(.context(ctx)) }
            if self.looking { self.ask(.look) }
            self.offerKey()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.deliver(.canSend(reachable))
            if reachable, self.looking { self.ask(.look) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchContext.key] as? Data, let ctx = WatchContext.unpacked(data) else { return }
        Task { @MainActor in self.deliver(.context(ctx)) }
    }

    /// Tomorrow's prices for the complication, sent while the app slept.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchContext.key] as? Data, let ctx = WatchContext.unpacked(data) else { return }
        Task { @MainActor in self.deliver(.context(ctx)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let news = WatchNews.from(messageData) else { return }
        Task { @MainActor in self.deliver(.news(news)) }
    }
}
