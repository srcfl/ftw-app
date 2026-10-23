import Foundation
import FTWShared
import os

/// The phone when it answers, FTW Cloud when it does not, behind one face,
/// so no screen knows which carried what. The rules are `WatchRoute`'s;
/// this holds the paths and the waits.
///
/// - Reads: the phone is asked whenever the watch looks. FTW Cloud is read
///   once each time the app comes on screen, at once when the phone cannot
///   be reached and after a short wait for the phone otherwise (a phone
///   simulator says it is reachable even when it is off). Records from both
///   meet in `WatchContext.merging`, where the newer wins, so nothing steps
///   back. No timer reads again while the watch stays on screen.
/// - Commands: through the phone when it is reachable, until the box's ack
///   comes back through it. FTW Cloud carries one too when the phone cannot
///   be reached, says it could not send it, or has not passed on the ack
///   within `WatchRoute.phoneTakesMs`. Both carry the watch's own `cmdId`,
///   and the box acts on it once.
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
    private var route = WatchRoute()
    private var pendingRead: Task<Void, Never>?

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
        phone.look()
        guard let wait = route.look(phone: reach.phone, nowMs: WatchClock.ms()) else { return }
        pendingRead?.cancel()
        pendingRead = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
            // Gone from the screen, or the phone answered the look: its
            // stream is the fresher path.
            guard let self, !Task.isCancelled, self.route.readsCloud else { return }
            await self.cloud.read(looking: true, kept: self.kept)
        }
    }

    func away() {
        route.away()
        pendingRead?.cancel()
        phone.away()
    }

    /// A read while the app is not on screen: a complication's refresh.
    func refresh() async {
        await cloud.read(looking: false, kept: kept)
    }

    func send(_ command: WatchCommand) {
        switch route.send(command, phone: reach.phone, cloud: cloud.ready, nowMs: WatchClock.ms()) {
        case .phone:
            phone.send(command)
            guard cloud.ready else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(WatchRoute.phoneTakesMs)))
                guard let self, let carry = self.route.phoneSlow(command.id, cloud: self.cloud.ready, nowMs: WatchClock.ms()) else { return }
                await self.viaTheCloud(carry)
            }
        case .cloud(let carry):
            Task { await viaTheCloud(carry) }
        case .nowhere:
            sink?(.news(.receipt(.box(command, .needsPhone))))
        }
    }

    /// A command through FTW Cloud, and one read after the box applied it,
    /// so the car on screen shows what it does now.
    private func viaTheCloud(_ carry: WatchRoute.Carry) async {
        guard await cloud.send(carry.command, leftMs: carry.leftMs), route.looking else { return }
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
            let r = route.phoneNotSent(id, cloud: cloud.ready, nowMs: WatchClock.ms())
            if let carry = r.carry {
                Task { await viaTheCloud(carry) }
            } else if r.tell {
                sink?(event)
            }
        case .context(let ctx):
            cloud.take(ctx.link)
            sink?(event)
            publish()
        case .news(let news):
            route.heardPhone(nowMs: WatchClock.ms())
            if case .receipt(let r) = news {
                // The phone could not send it: FTW Cloud carries it, and the
                // phone's word does not reach the screen.
                if let carry = route.phoneSaid(r, cloud: cloud.ready, nowMs: WatchClock.ms()) {
                    Task { await viaTheCloud(carry) }
                }
                guard route.shows(r) else { return }
            }
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
