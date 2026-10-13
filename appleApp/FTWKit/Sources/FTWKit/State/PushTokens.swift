import Foundation
import Synchronization

/// Which of Apple's push services a token belongs to. A development build
/// gets sandbox tokens.
public enum PushEnvironment: String, Sendable {
    case sandbox, production
}

/// Takes the phone's APNs token. FTW Cloud's channel is the one that will:
/// it tells the service, over the app session, where Apple can reach this
/// phone.
public protocol PushTokenSink: Sendable {
    func register(apnsToken: Data, environment: PushEnvironment) async
}

/// The token Apple gave this phone, and who takes it.
///
/// Nothing asks for notifications until something wants them: a sink
/// arrives when FTW Cloud is on, and only then is the person asked. Once
/// they said yes, Apple hands a token at every launch. A sink installed
/// later gets the latest at once. Kept in memory: Apple gives it again at
/// the next launch.
public enum PushTokens {
    public struct Token: Sendable, Equatable {
        public var data: Data
        public var environment: PushEnvironment
    }

    private struct State {
        var sink: (any PushTokenSink)?
        var token: Token?
        var ask: (@Sendable () async -> Void)?
    }

    private static let state = Mutex(State())

    /// The app sets this at launch: ask the person to allow notifications,
    /// then register with Apple.
    public static func setAsk(_ ask: @escaping @Sendable () async -> Void) {
        state.withLock { $0.ask = ask }
    }

    /// Something wants pushes. It gets the token now if there is one and
    /// whenever it changes; the person is asked if nobody has asked yet.
    public static func install(_ sink: any PushTokenSink) async {
        let (token, ask) = state.withLock { s in
            s.sink = sink
            return (s.token, s.ask)
        }
        if let token { await sink.register(apnsToken: token.data, environment: token.environment) }
        await ask?()
    }

    /// Nothing wants pushes any more.
    public static func uninstall() {
        state.withLock { $0.sink = nil }
    }

    /// Apple gave a token. The same token twice is handed over once.
    public static func received(_ data: Data, environment: PushEnvironment) async {
        let token = Token(data: data, environment: environment)
        let sink = state.withLock { s -> (any PushTokenSink)? in
            defer { s.token = token }
            return s.token == token ? nil : s.sink
        }
        await sink?.register(apnsToken: data, environment: environment)
    }

    public static var current: Token? {
        state.withLock { $0.token }
    }
}
