import Foundation
import Synchronization
import Testing
@testable import FTWKit
import FTWShared

/// `PushTokens` for one site model, without the process-wide state another
/// suite may be using.
final class FakeTokens: Sendable {
    let sink = Mutex<(any PushTokenSink)?>(nil)

    var source: PushTokenSource {
        PushTokenSource(install: { s in self.sink.withLock { $0 = s } }, uninstall: { self.sink.withLock { $0 = nil } })
    }

    var installed: (any PushTokenSink)? { sink.withLock { $0 } }
}

/// FTW Cloud and the phone's pushes: the token goes to the service over the
/// app session, and the notification extension gets what the box said over
/// Noise.
@MainActor
@Suite struct CloudPushTests {
    /// push.register in the service's field names, only over an open
    /// session.
    @Test func theCarrierRegistersOverItsOpenSession() async throws {
        let rig = try CloudRig()
        let token = Data(repeating: 0xa2, count: 32)
        #expect(!rig.carrier.pushRegister(apnsToken: token, environment: .sandbox))
        rig.carrier.start()
        await rig.run(50)
        #expect(rig.carrier.pushRegister(apnsToken: token, environment: .production))
        await rig.run(30)
        let sent = try #require(rig.service.received.first { $0.t == CloudWire.msgPushRegister })
        let body = try decodeCBOR(sent.b)
        #expect(body["apnsToken"]?.byteString == Bytes(token))
        #expect(body["environment"]?.string == "production")
        #expect(body["kind"]?.string == "alert")
    }

    /// While FTW Cloud is on, its session takes the token: at the opening,
    /// at every reopening, and at once when Apple gives a new one. Turning
    /// FTW Cloud off lets go of it.
    @Test func theTokenGoesOutAtEveryOpening() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(0)
        let sink = try #require(w.tokens.installed)
        await sink.register(apnsToken: Data([1, 2, 3]), environment: .sandbox)
        #expect(w.service.registrations.isEmpty)
        await w.run(60)
        #expect(w.service.registrations == [[1, 2, 3]])

        w.service.close(code: 1006)
        await w.run(600)
        #expect(w.site.cloudStatus?.isOpen == true)
        #expect(w.service.registrations == [[1, 2, 3], [1, 2, 3]])

        await sink.register(apnsToken: Data([4, 5, 6]), environment: .sandbox)
        await w.run(30)
        #expect(w.service.registrations.last == [4, 5, 6])

        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: nil)
        await w.run(30)
        #expect(w.tokens.installed == nil)
    }

    /// hello gives the notification extension the box's key and names, the
    /// next write adds rule U's anchor, and turning FTW Cloud off takes the
    /// home away.
    @Test func helloSharesTheHomeWithTheExtension() async throws {
        let w = try CloudSite(noClock: true)
        w.open()
        w.connectCloud()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        await w.run(60)
        let keys = CloudKeys(directory: w.shared.directory)
        let row = try #require(keys.read(home: w.identity.home))
        #expect(row.siteId == "s1")
        #expect(row.boxKey == Data(w.identity.pk))
        #expect(row.sources == ["m": "p1meter"])

        w.site.persistNow()
        let offset = try #require(keys.offset(home: w.identity.home))
        #expect(offset.boot == w.identity.boot)
        #expect(offset.offsetMs == w.box.start)

        w.relay.helloOk(uptimeMs: w.uptime, cloud: nil)
        await w.run(30)
        #expect(keys.read(home: w.identity.home) == nil)
    }

    /// The demo has no FTW Cloud and leaves nothing for the extension.
    @Test func theDemoSharesNothing() async throws {
        let w = try CloudSite()
        w.site = SiteModel(siteId: "s1", build: "test", ua: "test", scheduler: w.scheduler, files: w.files, shared: w.shared, isDemo: true)
        w.site.pushTokens = w.tokens.source
        w.site.start()
        w.connectCloud()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        await w.run(60)
        #expect(CloudKeys(directory: w.shared.directory).read(home: w.identity.home) == nil)
        #expect(w.tokens.installed == nil)
    }
}
