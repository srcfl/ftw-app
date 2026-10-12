import Foundation

/// Time, as everything above the wire sees it: a wall clock and timers.
///
/// Injected so the carrier backoffs, the session's deadlines and every
/// retry can be tested by moving a clock rather than by waiting. The app
/// uses `LiveScheduler`; tests use `ManualScheduler`.
@MainActor
public protocol Scheduler: AnyObject {
    /// Wall clock, in milliseconds since 1970.
    var nowMs: Double { get }
    /// Run `action` once after `ms`. Cancelling is always safe, even after
    /// it has run.
    @discardableResult
    func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> Cancellable
    /// A number in [0, 1), for jitter.
    func random() -> Double
}

@MainActor
public final class Cancellable {
    private var cancelled = false
    private let onCancel: (() -> Void)?

    init(onCancel: (() -> Void)? = nil) {
        self.onCancel = onCancel
    }

    public var isCancelled: Bool { cancelled }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel?()
    }
}

@MainActor
public final class LiveScheduler: Scheduler {
    public static let shared = LiveScheduler()

    public init() {}

    public var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    public func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> Cancellable {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
            if Task.isCancelled { return }
            action()
        }
        let token = Cancellable { task.cancel() }
        return token
    }

    public func random() -> Double { Double.random(in: 0..<1) }
}

/// A clock that only moves when a test says so.
@MainActor
public final class ManualScheduler: Scheduler {
    private struct Pending {
        let at: Double
        let seq: Int
        let token: Cancellable
        let action: @MainActor () -> Void
    }

    public private(set) var nowMs: Double
    private var pending: [Pending] = []
    private var seq = 0
    public var randomValue: Double = 0.5

    public init(nowMs: Double = 1_750_000_000_000) {
        self.nowMs = nowMs
    }

    public func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> Cancellable {
        let token = Cancellable()
        seq += 1
        pending.append(Pending(at: nowMs + max(0, ms), seq: seq, token: token, action: action))
        return token
    }

    public func random() -> Double { randomValue }

    /// Move time forward, running every timer that falls due, in order.
    public func advance(_ ms: Double) {
        let target = nowMs + ms
        while true {
            pending.removeAll { $0.token.isCancelled }
            guard let next = pending.filter({ $0.at <= target }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) else { break }
            pending.removeAll { $0.seq == next.seq }
            nowMs = max(nowMs, next.at)
            next.action()
        }
        nowMs = target
    }

    public var pendingCount: Int {
        pending.filter { !$0.token.isCancelled }.count
    }
}
