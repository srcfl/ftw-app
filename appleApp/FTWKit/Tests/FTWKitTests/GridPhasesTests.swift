import Foundation
import Testing
@testable import FTWKit
import FTWShared

/// The grid's phases against the main fuse: what the node view draws from
/// the box's extra fields.
@Suite struct GridPhasesTests {
    typealias F = Contract.FID

    /// The home box on 14 October 2026: L1 and L3 sold while L2 bought,
    /// under a 20 A fuse.
    let home: [Int: Double] = [F.gridW: 112, F.gridL1DA: -37, F.gridL2DA: 60, F.gridL3DA: -29, F.gridFuseDA: 200]

    @Test func eachPhaseIsItsSizeAgainstTheFuse() throws {
        let p = try #require(GridPhases.read(fields: home, live: true))
        #expect(p.phases.map(\.name) == ["L1", "L2", "L3"])
        #expect(p.phases.map(\.amps) == [3.7, 6.0, 2.9])
        #expect(p.fuseA == 20)
        #expect(abs((p.phases[1].ofFuse ?? 0) - 0.3) < 1e-9)
        #expect(p.nearest == 1)
    }

    /// At the largest standard text size the decimal goes, never the
    /// figure: no "…".
    @Test func theLargestTextDropsTheDecimal() throws {
        let p = try #require(GridPhases.read(fields: [F.gridL1DA: 162, F.gridFuseDA: 200], live: true))
        AppWords.$language.withValue(.en) {
            #expect(p.reading(p.phases[0]) == "16.2\u{00A0}A")
            #expect(p.reading(p.phases[0], decimals: 0) == "16\u{00A0}A")
        }
    }

    /// A meter that gives no phases shows nothing: not three idle meters,
    /// and not the fuse on its own.
    @Test func noPhasesNoRow() {
        #expect(GridPhases.read(fields: [F.gridW: 1200], live: true) == nil)
        #expect(GridPhases.read(fields: [F.gridW: 1200, F.gridFuseDA: 200], live: true) == nil)
    }

    /// While not live the row keeps its room but shows no number: an old
    /// phase current says nothing about the fuse now.
    @Test func notLiveShowsNoNumber() throws {
        let p = try #require(GridPhases.read(fields: home, live: false))
        #expect(p.phases.count == 3)
        #expect(p.phases.allSatisfy { $0.amps == nil && $0.ofFuse == nil })
        #expect(p.nearest == nil)
        #expect(p.phases.map { p.reading($0) } == ["—", "—", "—"])
    }

    /// A one-phase site sends L1 alone, and the row draws one meter.
    @Test func onlyThePhasesTheBoxSends() throws {
        let p = try #require(GridPhases.read(fields: [F.gridL1DA: 95, F.gridFuseDA: 250], live: true))
        #expect(p.phases.map(\.name) == ["L1"])
        #expect(p.nearest == 0)
    }

    /// Two phases equally near: the first is marked, so the mark does not
    /// flicker between them.
    @Test func theFirstOfEqualsIsNearest() throws {
        let p = try #require(GridPhases.read(fields: [F.gridL1DA: 40, F.gridL2DA: -60, F.gridL3DA: 60, F.gridFuseDA: 160], live: true))
        #expect(p.nearest == 1)
    }

    /// Without a fuse there is no scale, so nothing is marked.
    @Test func noFuseNoMark() throws {
        let p = try #require(GridPhases.read(fields: [F.gridL1DA: 40], live: true))
        #expect(p.fuseA == nil)
        #expect(p.nearest == nil)
        #expect(p.phases[0].ofFuse == nil)
        #expect(p.phases[0].amps == 4)
    }

    @Test func wordsInSwedishAndEnglish() throws {
        let p = try #require(GridPhases.read(fields: home, live: true))
        AppWords.$language.withValue(.sv) {
            #expect(p.kicker == "FASER · SÄKRING 20\u{00A0}A")
            #expect(p.reading(p.phases[1]) == "6,0\u{00A0}A")
            #expect(p.spoken == "L1 3,7\u{00A0}A; L2 6,0\u{00A0}A, närmast säkringen; L3 2,9\u{00A0}A")
            #expect(GridPhases.read(fields: home, live: false)?.spoken == "Faserna är inte live.")
        }
        AppWords.$language.withValue(.en) {
            #expect(p.kicker == "PHASES · FUSE 20\u{00A0}A")
            #expect(p.reading(p.phases[0]) == "3.7\u{00A0}A")
        }
    }
}
