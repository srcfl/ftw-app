import Foundation
import Synchronization
import Testing
@testable import FTWKit

/// The APNs token's way to FTW Cloud: whoever wants it gets the latest, once
/// per change, and the person is asked only when something wants pushes.
@Suite struct PushTokensTests {
    final class Sink: PushTokenSink {
        let got = Mutex<[PushTokens.Token]>([])

        func register(apnsToken: Data, environment: PushEnvironment) async {
            got.withLock { $0.append(PushTokens.Token(data: apnsToken, environment: environment)) }
        }
    }

    @Test func theSinkGetsEachTokenOnce() async {
        let asked = Mutex(0)
        PushTokens.setAsk { asked.withLock { $0 += 1 } }
        defer { PushTokens.uninstall() }
        let a = Data([1, 2, 3])
        let b = Data([4, 5, 6])

        // A token from an earlier yes, before anything wants it.
        await PushTokens.received(a, environment: .sandbox)
        #expect(asked.withLock { $0 } == 0)
        #expect(PushTokens.current == PushTokens.Token(data: a, environment: .sandbox))

        let sink = Sink()
        await PushTokens.install(sink)
        #expect(asked.withLock { $0 } == 1)
        // Apple hands the same token again after the ask: not repeated.
        await PushTokens.received(a, environment: .sandbox)
        await PushTokens.received(b, environment: .sandbox)
        #expect(sink.got.withLock { $0 } == [.init(data: a, environment: .sandbox), .init(data: b, environment: .sandbox)])

        PushTokens.uninstall()
        await PushTokens.received(a, environment: .production)
        #expect(sink.got.withLock { $0 }.count == 2)
    }
}
