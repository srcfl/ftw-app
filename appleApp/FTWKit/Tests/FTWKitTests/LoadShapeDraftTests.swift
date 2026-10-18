import Foundation
import Testing
@testable import FTWKit

@Suite struct LoadShapeDraftTests {
    private let quarter = 900_000.0

    private func draft(_ values: [Double], fromMs: Double = 0) throws -> LoadShapeDraft {
        try LoadShapeDraft(slots: values.enumerated().map { i, watts in
            .init(startMs: fromMs + Double(i) * quarter,
                  endMs: fromMs + Double(i + 1) * quarter, baseWatts: watts)
        })
    }

    @Test func raisesAZeroColdStartInWatts() throws {
        let base = try draft([0, 0, 0])
        let raised = try base.pulling(atMs: 1.5 * quarter, byWatts: 500, radiusMs: quarter, nowMs: 0)
        #expect(raised.slots.map(\.watts) == [0, 500, 0])
        #expect(base.slots.map(\.watts) == [0, 0, 0])
    }

    @Test func nearbyIntervalsMoveLessAndDistantOnesStayPut() throws {
        let base = try draft(Array(repeating: 1_000, count: 7))
        let changed = try base.pulling(atMs: 3.5 * quarter, byWatts: 800, radiusMs: 2 * quarter, nowMs: 0)
        #expect(changed.slots.map(\.watts) == [1_000, 1_000, 1_337.5, 1_800, 1_337.5, 1_000, 1_000])
    }

    @Test func pastAndInFlightIntervalsStayPut() throws {
        let base = try draft([700, 800, 900])
        let changed = try base.pulling(atMs: 1.5 * quarter, byWatts: -500, radiusMs: 3 * quarter, nowMs: quarter + 1)
        #expect(changed.slots[0] == base.slots[0])
        #expect(changed.slots[1] == base.slots[1])
        #expect(changed.slots[2].watts < 900)
    }

    @Test func aDownwardPullStopsAtZeroAndKeepsTheBase() throws {
        let changed = try draft([200]).pulling(atMs: quarter / 2, byWatts: -600, radiusMs: quarter, nowMs: 0)
        #expect(changed.slots[0].watts == 0)
        #expect(changed.slots[0].baseWatts == 200)
        #expect(changed.changes(nowMs: 0).count == 1)
    }

    @Test func returningTheFingerToItsStartRestoresTheGestureSnapshot() throws {
        let before = try draft([800, 1_000, 800])
        // The UI replaces its preview from `before` on every event.
        for delta in [100.0, 350, -200] {
            _ = try before.pulling(atMs: 1.5 * quarter, byWatts: delta, radiusMs: 2 * quarter, nowMs: 0)
        }
        let returned = try before.pulling(atMs: 1.5 * quarter, byWatts: 0, radiusMs: 2 * quarter, nowMs: 0)
        #expect(returned == before)
        #expect(returned.changes(nowMs: 0).isEmpty)
    }

    @Test func aLaterGestureCanReshapeAnExistingEditAndUndoIsAValue() throws {
        let base = try draft([800])
        let first = try base.pulling(atMs: quarter / 2, byWatts: 500, radiusMs: quarter, nowMs: 0)
        let second = try first.pulling(atMs: quarter / 2, byWatts: -300, radiusMs: quarter, nowMs: 0)
        #expect(second.slots[0].watts == 1_000)
        #expect(first.slots[0].watts == 1_300)
        #expect(base.slots[0].watts == 800)
    }

    @Test func resetOnlyClearsEditsInTheSelectedFutureWindow() throws {
        let base = try draft([500, 500, 500, 500])
        let changed = try base.pulling(atMs: 2 * quarter, byWatts: 400, radiusMs: 4 * quarter, nowMs: 0)
        let reset = changed.resetting(in: quarter..<(3 * quarter), nowMs: quarter)
        #expect(reset.slots[0] == changed.slots[0])
        #expect(reset.slots[1] == base.slots[1])
        #expect(reset.slots[2] == base.slots[2])
        #expect(reset.slots[3] == changed.slots[3])
    }

    @Test func anExpiredEditIsNeverSubmitted() throws {
        let changed = try draft([500, 500]).pulling(atMs: quarter, byWatts: 400, radiusMs: 2 * quarter, nowMs: 0)
        #expect(changed.changes(nowMs: 1).map(\.startMs) == [quarter])
        #expect(changed.changes(nowMs: 2 * quarter).isEmpty)
    }

    @Test func gapsStayMissing() throws {
        let base = try LoadShapeDraft(slots: [
            .init(startMs: 0, endMs: quarter, baseWatts: 500),
            .init(startMs: 3 * quarter, endMs: 4 * quarter, baseWatts: 500),
        ])
        let changed = try base.pulling(atMs: 2 * quarter, byWatts: 300, radiusMs: 4 * quarter, nowMs: 0)
        #expect(changed.slots.count == 2)
        #expect(changed.slots.map(\.startMs) == [0, 3 * quarter])
    }

    @Test func repeatedLocalHoursKeepDistinctUtcIntervals() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!.timeIntervalSince1970 * 1_000
        let base = try draft(Array(repeating: 500, count: 8), fromMs: start)
        let changed = try base.pulling(atMs: start + 4.5 * quarter, byWatts: 300, radiusMs: quarter, nowMs: start)
        #expect(changed.changes(nowMs: start).map(\.startMs) == [start + 4 * quarter])
        #expect(changed.slots[0].watts == 500)
        #expect(changed.slots[4].watts == 800)
    }

    @Test func invalidSlotsAreRejected() {
        for slots: [LoadShapeDraft.Slot] in [
            [.init(startMs: 0, endMs: 1, baseWatts: -.infinity)],
            [.init(startMs: 0, endMs: 1, baseWatts: -1)],
            [.init(startMs: .nan, endMs: 1, baseWatts: 100)],
            [.init(startMs: 1, endMs: 1, baseWatts: 100)],
            [.init(startMs: 0, endMs: .infinity, baseWatts: 100)],
            [.init(startMs: 0, endMs: 2, baseWatts: 100), .init(startMs: 1, endMs: 3, baseWatts: 100)],
        ] {
            #expect(throws: LoadShapeDraft.Invalid.slots) { try LoadShapeDraft(slots: slots) }
        }
    }

    @Test func invalidPullsAndOverflowAreRejectedWithoutChangingTheDraft() throws {
        let base = try draft([Double.greatestFiniteMagnitude])
        for (at, delta, radius, now): (Double, Double, Double, Double) in [
            (.nan, 100, quarter, 0), (quarter / 2, .infinity, quarter, 0),
            (quarter / 2, 100, 0, 0), (quarter / 2, 100, .infinity, 0),
            (quarter / 2, 100, quarter, .nan), (-1, 100, quarter, 0),
            (quarter / 2, .greatestFiniteMagnitude, quarter, 0),
        ] {
            #expect(throws: LoadShapeDraft.Invalid.pull) {
                try base.pulling(atMs: at, byWatts: delta, radiusMs: radius, nowMs: now)
            }
        }
        #expect(base.changes(nowMs: 0).isEmpty)
    }
}
