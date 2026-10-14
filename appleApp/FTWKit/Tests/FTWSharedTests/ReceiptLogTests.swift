import Foundation
import Testing
@testable import FTWShared

/// The receipt log under a car command: four reserved slots, each lit only
/// on its own evidence, and a refusal in the last.
@Suite struct ReceiptLogTests {
    /// Each slot lights on its own evidence, in whatever order it comes:
    /// the box often confirms before the car draws.
    @Test func eachSlotLightsOnItsOwnEvidence() {
        let sent = ReceiptLog()
        #expect(sent.marks.map(\.state) == [.lit, .waiting, .waiting, .waiting])
        let confirmedFirst = ReceiptLog(accepted: true, confirmed: true)
        #expect(confirmedFirst.marks.map(\.state) == [.lit, .lit, .waiting, .lit])
        let all = ReceiptLog(accepted: true, measured: true, confirmed: true)
        #expect(all.marks.map(\.state) == [.lit, .lit, .lit, .lit])
        #expect(all.line == "SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED")
    }

    /// A refusal takes the last slot with the box's reason; a confirmation
    /// never shows beside it.
    @Test func aRefusalTakesTheLastSlot() {
        let refused = ReceiptLog(accepted: true, confirmed: true, refused: "Plug the car in first.")
        #expect(refused.marks.last?.state == .refused)
        #expect(refused.marks.last?.text.trimmingCharacters(in: .whitespaces) == "REFUSED")
        #expect(!refused.lit(.confirmed))
        #expect(refused.line == "SENT ▸ ACCEPTED ▸ MEASURED ▸ REFUSED")
    }

    /// The last slot is as wide whether it says CONFIRMED or REFUSED, so the
    /// line never changes width.
    @Test func theLastSlotIsReserved() {
        let a = ReceiptLog(confirmed: true).marks.last!.text
        let b = ReceiptLog(refused: "no").marks.last!.text
        #expect(a.count == b.count)
        #expect(ReceiptLog().marks.map(\.text).joined().count == ReceiptLog(refused: "no").marks.map(\.text).joined().count)
    }

    /// Lane 0 is evidence only while live and above the beam threshold.
    @Test func measuredNeedsALiveReadingAboveTheThreshold() {
        #expect(ReceiptLog.drawingW == 42)
        #expect(ReceiptLog.measures(evW: 43, live: true))
        #expect(!ReceiptLog.measures(evW: 42, live: true))
        #expect(!ReceiptLog.measures(evW: 7_000, live: false))
        #expect(!ReceiptLog.measures(evW: nil, live: true))
    }

    @Test func everyReceiptWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in ReceiptWord.allCases {
            let sv = try #require(table[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(sv != word.rawValue)
            #expect(sv == sv.uppercased())
        }
        // The watch's receipt says the same words.
        #expect(table["SENT"] == "SKICKAT")
        #expect(table["ACCEPTED"] == "MOTTAGET")
        #expect(table["CONFIRMED"] == "BEKRÄFTAT")
    }
}
