import Foundation
import Testing
@testable import FTWShared

/// What the app leaves for the notification extension, and what the
/// extension remembers between pushes.
@Suite struct PushStoreTests {
    static let home = "fjzyr67buzpyncqmjliwgezvde"
    static let key = Data([0x04] + Array(repeating: 0x11, count: 64))

    static func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ftw-push-\(UUID().uuidString)", isDirectory: true)
    }

    static func event(home: String = home, boot: UInt8 = 0xb0, seq: UInt64) -> PushAlert {
        PushAlert(.event, home: home, kind: PushKind.chargingConnected, boot: Data(repeating: boot, count: 16), seq: seq, atMs: 1)
    }

    // MARK: CloudKeys

    @Test func aHomeReadsBackAsWritten() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = CloudKeys(directory: dir)
        let row = CloudHome(home: Self.home, siteId: "site", boxKey: Self.key, loadpoints: ["j3HZORNCWHs": "garage"], sources: ["DUYWWQmn-Xg": "Easee"])
        try keys.write(row)
        #expect(keys.read(home: Self.home) == row)
        #expect(keys.boxKey(home: Self.home) == Self.key)
        #expect(keys.read(home: "t3w5bfotxeygcjxjdhjaeo6pvq") == nil)
        keys.remove(home: Self.home)
        #expect(keys.read(home: Self.home) == nil)
    }

    /// The home id comes from a push. It never names a file outside the
    /// store, and a key that is not a point is refused at the door.
    @Test func onlyAHomeIDAndAPointAreKept() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = CloudKeys(directory: dir)
        for bad in ["../../etc/passwd", "FJZYR67BUZPYNCQMJLIWGEZVDE", "fjzyr67buzpyncqmjliwgezvd", "fjzyr67buzpyncqmjliwgezvd1", ""] {
            #expect(!CloudKeys.isHomeID(bad), "\(bad)")
            #expect(throws: CloudKeys.Refused.self) { try keys.write(CloudHome(home: bad, siteId: "s", boxKey: Self.key)) }
            #expect(keys.read(home: bad) == nil)
        }
        #expect(CloudKeys.isHomeID(Self.home))
        #expect(throws: CloudKeys.Refused.self) { try keys.write(CloudHome(home: Self.home, siteId: "s", boxKey: Data(Self.key.dropFirst()))) }
        #expect(throws: CloudKeys.Refused.self) { try keys.write(CloudHome(home: Self.home, siteId: "s", boxKey: Data([0x02]) + Self.key.dropFirst())) }
    }

    /// The event's charger, through the box's table. A home with one
    /// charger needs no name for it; an unknown name is not guessed.
    @Test func theChargerAnEventMeans() {
        let one = CloudHome(home: Self.home, siteId: "s", boxKey: Self.key, loadpoints: ["j3HZORNCWHs": "garage"])
        #expect(one.loadpointID(opaque: "j3HZORNCWHs") == "garage")
        #expect(one.loadpointID(opaque: nil) == "garage")
        #expect(one.loadpointID(opaque: "unknown") == nil)
        let two = CloudHome(home: Self.home, siteId: "s", boxKey: Self.key, loadpoints: ["a": "garage", "b": "street"])
        #expect(two.loadpointID(opaque: nil) == nil)
        #expect(two.loadpointID(opaque: "b") == "street")
        #expect(CloudHome(home: Self.home, siteId: "s", boxKey: Self.key).loadpointID(opaque: nil) == nil)
    }

    // MARK: PushSeen

    @Test func anEventIsShownOnce() {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = PushSeen(file: dir.appendingPathComponent("push-seen"))
        #expect(seen.accept(Self.event(seq: 9), nowMs: 1))
        #expect(!seen.accept(Self.event(seq: 9), nowMs: 2))
        // Older than one shown.
        #expect(!seen.accept(Self.event(seq: 8), nowMs: 3))
        #expect(seen.accept(Self.event(seq: 10), nowMs: 4))
        // A restart counts again; another home counts on its own.
        #expect(seen.accept(Self.event(boot: 0xc0, seq: 1), nowMs: 5))
        #expect(seen.accept(Self.event(home: "t3w5bfotxeygcjxjdhjaeo6pvq", seq: 9), nowMs: 6))
        // Remembered across processes: a fresh reader of the same file.
        #expect(!PushSeen(file: seen.file).accept(Self.event(seq: 10), nowMs: 7))
        // Only events carry a number.
        #expect(seen.accept(PushAlert(.unreachable, home: Self.home), nowMs: 8))
        #expect(seen.accept(PushAlert(.unreachable, home: Self.home), nowMs: 9))
        #expect(seen.accept(PushAlert(.generic, home: Self.home), nowMs: 10))
    }

    @Test func theFileStaysSmall() {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = PushSeen(file: dir.appendingPathComponent("push-seen"))
        for boot in 0..<UInt8(PushSeen.limit + 8) {
            #expect(seen.accept(Self.event(boot: boot, seq: 1), nowMs: Double(boot)))
        }
        let kept = seen.load()
        #expect(kept.count == PushSeen.limit)
        // The oldest went first.
        #expect(!kept.contains { $0.boot == Data(repeating: 0, count: 16) })
        #expect(kept.contains { $0.boot == Data(repeating: UInt8(PushSeen.limit + 7), count: 16) })
    }
}
