import Foundation
import FTWShared
import os

/// The phone when it answers, FTW Cloud when it does not, behind one face,
/// so no screen knows which carried what.
///
/// - Reads: the phone is asked whenever the watch looks. FTW Cloud is read
///   once each time the app comes on screen, at once when the phone cannot
///   be reached and after a short wait for the phone otherwise (a phone
///   simulator says it is reachable even when it is off). Records from both
///   meet in `WatchContext.merging`, where the newer wins, so nothing steps
///   back. No timer reads again while the watch stays on screen.
/// - Commands: through the phone when it is reachable; through FTW Cloud
///   when it is not, when the phone could not take the command, or when it
///   has not said it has it within `phoneTakesMs` (a phone simulator says it
///   is reachable when it is off, and a real phone can be slow to wake).
///   Both carry the watch's own `cmdId`, and the box acts on it once.
/// - Whether commands can leave is the phone's reach or FTW Cloud's,
///   whichever holds, and changes only when that answer does, so the
///   buttons never blink while the paths change places.
@MainActor
final class PathChooser: ReadPath, CommandPath {
    private let phone: PhonePath
    let cloud: CloudPath
    private var sink: PathSink?
    /// The model's context, for what a cloud read keeps from the phone.
    var kept: @MainActor () -> WatchContext? = { nil }

    private var reach = WatchReach()
    private var phoneReachable: Bool { reach.phone }
    private var looking = false
    /// When the phone last answered: a frame or a receipt. The context it
    /// left before this app started is not an answer.
    private var phoneHeardAtMs: Double = 0
    private var pendingRead: Task<Void, Never>?
    /// Commands sent through the phone, until it answers, so one it could
    /// not take goes through FTW Cloud instead.
    private var viaPhone: [String: WatchCommand] = [:]
    /// Commands FTW Cloud carries: the phone's word that it could not take
    /// one of these says nothing about it.
    private var viaCloud = Set<String>()

    /// How long the phone has to answer a look before FTW Cloud is read.
    static let phoneWaitMs: Double = 2_500
    /// How long the phone has to say it has a command before FTW Cloud
    /// carries it too.
    static let phoneTakesMs: Double = 3_000

    private var nowMs: Double { Date.now.timeIntervalSince1970 * 1000 }

    init(phone: PhonePath = PhonePath(), cloud: CloudPath = CloudPath()) {
        self.phone = phone
        self.cloud = cloud
    }

    func start(_ sink: @escaping PathSink) {
        self.sink = sink
        #if DEBUG
        // `-FTWWatchLink <base64 JSON>`: a link for a simulator against a
        // local box, with no phone to hand it over.
        if let raw = UserDefaults.standard.string(forKey: "FTWWatchLink"), let data = Data(base64Encoded: raw),
           let link = try? JSONDecoder().decode(WatchLink.self, from: data) {
            cloud.take(link)
        }
        #endif
        // The link the watch kept from its phone, before any path speaks.
        cloud.take(kept()?.link)
        cloud.start { [weak self] in self?.fromCloud($0) }
        phone.start { [weak self] in self?.fromPhone($0) }
        publish()
    }

    func look() {
        let appeared = !looking
        looking = true
        phone.look()
        guard appeared else { return }
        pendingRead?.cancel()
        let asked = nowMs
        let wait = phoneReachable ? Self.phoneWaitMs : 0
        pendingRead = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
            guard let self, !Task.isCancelled, self.looking else { return }
            // The phone answered the look: its stream is the fresher path.
            if self.phoneHeardAtMs >= asked { return }
            await self.cloud.read(looking: true, kept: self.kept)
        }
    }

    func away() {
        looking = false
        pendingRead?.cancel()
        phone.away()
    }

    /// A read while the app is not on screen: a complication's refresh.
    func refresh() async {
        await cloud.read(looking: false, kept: kept)
    }

    func send(_ command: WatchCommand) {
        guard phoneReachable else {
            viaCloud.insert(command.id)
            Task { await viaTheCloud(command) }
            return
        }
        viaPhone[command.id] = command
        phone.send(command)
        guard cloud.ready else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.phoneTakesMs)))
            guard let self, let c = self.viaPhone.removeValue(forKey: command.id) else { return }
            self.viaCloud.insert(c.id)
            await self.viaTheCloud(c)
        }
    }

    /// A command through FTW Cloud, and one read after the box applied it,
    /// so the car on screen shows what it does now.
    private func viaTheCloud(_ c: WatchCommand) async {
        guard await cloud.send(c), looking else { return }
        try? await Task.sleep(for: .milliseconds(Int(Self.afterCommandMs)))
        await cloud.read(looking: true, kept: kept)
    }

    /// How long after an applied command the box's next reading has left.
    static let afterCommandMs: Double = 2_000

    // MARK: What the paths say

    private func fromPhone(_ event: PathEvent) {
        switch event {
        case .canSend(let ok):
            publish(phone: ok)
        case .notSent(let id):
            // The phone could not take it: FTW Cloud carries the same
            // command, under the same cmdId.
            if let c = viaPhone.removeValue(forKey: id), cloud.ready {
                viaCloud.insert(c.id)
                Task { await viaTheCloud(c) }
            } else if !viaCloud.contains(id) {
                sink?(event)
            }
        case .context(let ctx):
            cloud.take(ctx.link)
            sink?(event)
            publish()
        case .news(let news):
            phoneHeardAtMs = nowMs
            // The phone has the command: it carries it alone.
            if case .receipt(let r) = news { viaPhone[r.commandID] = nil }
            sink?(event)
        case .phoneReachable:
            sink?(event)
        }
    }

    private func fromCloud(_ event: PathEvent) {
        sink?(event)
    }

    /// Tell the model what can leave, only when it changed.
    private func publish(phone: Bool? = nil) {
        for change in reach.set(phone: phone, cloud: cloud.ready) {
            switch change {
            case .canSend(let ok): sink?(.canSend(ok))
            case .phoneReachable(let ok): sink?(.phoneReachable(ok))
            }
        }
    }
}
