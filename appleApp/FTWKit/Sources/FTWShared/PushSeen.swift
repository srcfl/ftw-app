import Foundation
import Synchronization

/// Events this phone has shown, so a push that arrives twice is shown once.
///
/// The box numbers what it sends: `seq` rises by one per message within a
/// boot. Per home and boot the extension keeps the highest `seq` it showed;
/// an event at or below it is a duplicate or older than one already shown.
/// A new boot starts its own count. The file keeps the most recent few
/// boots and is in the App Group, beside the cache.
public struct PushSeen: Sendable {
    public let file: URL
    /// Homes times boots worth remembering. Each box starts a new boot on
    /// every restart; the oldest goes first.
    public static let limit = 32

    public init(file: URL) {
        self.file = file
    }

    public static func shared(bundle: Bundle = .main) -> PushSeen? {
        AppGroupFiles.shared(bundle: bundle).map { PushSeen(file: $0.directory.appendingPathComponent("push-seen")) }
    }

    struct Entry: Codable, Equatable {
        var home: String
        var boot: Data
        var seq: UInt64
        /// The phone's clock when it was last moved, to drop the oldest.
        var atMs: Double
    }

    /// Whether to show this alert. A new event is remembered before the
    /// answer, so a second copy that arrives meanwhile is not. Only events
    /// carry a number; the rest are always shown. If the file cannot be
    /// written the event is shown anyway: a duplicate is better than a
    /// missed alert.
    public func accept(_ alert: PushAlert, nowMs: Double) -> Bool {
        guard alert.verdict == .event else { return true }
        let boot = alert.boot ?? Data()
        return Self.lock.withLock { _ in
            var entries = load()
            if let i = entries.firstIndex(where: { $0.home == alert.home && $0.boot == boot }) {
                guard alert.seq > entries[i].seq else { return false }
                entries[i].seq = alert.seq
                entries[i].atMs = nowMs
            } else {
                entries.append(Entry(home: alert.home, boot: boot, seq: alert.seq, atMs: nowMs))
            }
            entries.sort { $0.atMs > $1.atMs }
            try? save(Array(entries.prefix(Self.limit)))
            return true
        }
    }

    private static let lock = Mutex(())

    func load() -> [Entry] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
