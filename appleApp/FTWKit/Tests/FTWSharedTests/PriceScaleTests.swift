import Foundation
import Testing
@testable import FTWShared

/// The price axis from zero: a round top just over the dearest, so a bar's
/// height is its price. Erik's morning, 438 to 556 öre, is the case that
/// started it.
@Suite struct PriceScaleTests {
    @Test func theTopIsTheFirstRoundFigureOverTheDearest() {
        #expect(PriceScale.round(556) == 600)
        #expect(PriceScale.round(182) == 200)
        #expect(PriceScale.round(142) == 150)
        #expect(PriceScale.round(50) == 50)
        #expect(PriceScale.round(1_250) == 1_500)
        #expect(PriceScale.round(2.3) == 2.5)
    }

    /// 438 öre stands at 73 % of the strip and 556 at 93 %: a fifth apart,
    /// as the prices are, not the floor against the top.
    @Test func ericsMorningReadsAsAFifthDearer() {
        let s = PriceScale([462, 438, 556, 528], currency: "SEK")
        #expect(s.top == 600 && s.bottom == 0)
        #expect(s.lines == [300, 600])
        #expect(abs(s.fraction(438) - 0.73) < 0.001)
        #expect(abs(s.fraction(556) - 0.9267) < 0.001)
        #expect(s.zero == 0)
        #expect(s.label(300) == "300")
    }

    /// A price below zero hangs under the zero line, on a round figure.
    @Test func aPriceBelowZeroHangsUnderTheLine() {
        let s = PriceScale([-12, 40, 96], currency: "SEK")
        #expect(s.top == 100 && s.bottom == -15)
        #expect(abs(s.zero - 15.0 / 115) < 1e-9)
        #expect(s.fraction(-12) < s.zero)
    }

    /// Nothing priced, or a window of zeros, still has a top, so a strip
    /// keeps its shape and draws nothing taller than the floor.
    @Test func anEmptyWindowKeepsItsShape() {
        let empty = PriceScale([], currency: "SEK")
        #expect(empty.top == 1 && empty.bottom == 0)
        #expect(PriceScale([0, 0], currency: "SEK").fraction(0) == 0)
    }

    /// The top rounds in the unit drawn: crowns for a Czech home, where a
    /// minor unit is a haléř.
    @Test func theTopRoundsInTheUnitDrawn() {
        let s = PriceScale([230], currency: "CZK")
        #expect(s.top == 250)
        #expect(s.label(250) == "2,5" || s.label(250) == "2.5")
    }
}
