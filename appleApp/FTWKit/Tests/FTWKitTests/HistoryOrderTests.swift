import Foundation
import Testing
@testable import FTWKit

/// The order of History's rows: what the phone keeps, what it draws from
/// it, and what it does with an order that no longer fits the home.
@Suite struct HistoryOrderTests {
    let all: [EnergyNode] = [.solar, .home, .battery, .grid, .car]

    func keys(_ rows: [HistoryRow]) -> String { HistoryOrder.stored(rows) }

    @Test func nothingStoredTellsTheDayInOrder() {
        let rows = HistoryOrder.rows(stored: "", nodes: all, price: true)
        #expect(keys(rows) == "solar,home,battery,grid,car,price")
    }

    @Test func aHomeIsOnlyDrawnTheRowsItHas() {
        let rows = HistoryOrder.rows(stored: "", nodes: [.solar, .home, .grid], price: false)
        #expect(keys(rows) == "solar,home,grid")
    }

    @Test func aStoredOrderIsKept() {
        let rows = HistoryOrder.rows(stored: "car,price,grid,solar,home,battery", nodes: all, price: true)
        #expect(keys(rows) == "car,price,grid,solar,home,battery")
    }

    @Test func aRowTheHomeHasNotGotIsLeftOut() {
        let rows = HistoryOrder.rows(stored: "car,price,grid,solar,home,battery", nodes: [.solar, .grid], price: false)
        #expect(keys(rows) == "grid,solar")
    }

    /// A box that starts serving prices, for an order saved before it did.
    @Test func priceTurningUpLandsWhereTheStandardOrderPutsIt() {
        let rows = HistoryOrder.rows(stored: "solar,home,battery,grid,car", nodes: all, price: true)
        #expect(keys(rows) == "solar,home,battery,grid,car,price")
    }

    /// A charger fitted today, in a History whose rows have been moved: the
    /// car comes in after the grid, the neighbour it follows when a day is
    /// told in order.
    @Test func aNodeTurningUpFollowsItsStandardNeighbour() {
        let rows = HistoryOrder.rows(stored: "grid,solar,home,battery", nodes: all, price: false)
        #expect(keys(rows) == "grid,car,solar,home,battery")
    }

    /// Nothing before it on screen: the row goes first.
    @Test func aNodeWithNoNeighbourBeforeItGoesFirst() {
        let rows = HistoryOrder.rows(stored: "grid,car", nodes: [.solar, .grid, .car], price: false)
        #expect(keys(rows) == "solar,grid,car")
    }

    @Test func aKeyFromAnotherVersionIsPassedOver() {
        let rows = HistoryOrder.rows(stored: "wind,grid,solar", nodes: [.solar, .home, .grid], price: false)
        #expect(keys(rows) == "grid,solar,home")
    }

    @Test func anOrderWithNothingLeftInItFallsBackOnTheStandardOne() {
        let rows = HistoryOrder.rows(stored: "wind,gas,,,", nodes: all, price: true)
        #expect(keys(rows) == "solar,home,battery,grid,car,price")
    }

    @Test func aRowStoredTwiceIsDrawnOnce() {
        let rows = HistoryOrder.rows(stored: "grid,grid,solar", nodes: [.solar, .grid], price: false)
        #expect(keys(rows) == "grid,solar")
    }

    /// A charger taken out and fitted again: the order the phone keeps
    /// still has the car, and draws it as soon as the home has it.
    @Test func aRowComesBackWhereItWasKept() {
        let stored = "car,solar,home,battery,grid"
        #expect(keys(HistoryOrder.rows(stored: stored, nodes: [.solar, .home, .battery, .grid], price: false))
            == "solar,home,battery,grid")
        #expect(keys(HistoryOrder.rows(stored: stored, nodes: all, price: false)) == stored)
    }

    @Test func whatIsDrawnIsWhatIsKept() {
        let rows = HistoryOrder.rows(stored: "price,car,grid", nodes: all, price: true)
        #expect(HistoryOrder.rows(stored: keys(rows), nodes: all, price: true) == rows)
    }

    @Test func aRowMovesUpAndDown() {
        let rows = HistoryOrder.rows(stored: "", nodes: all, price: false)
        #expect(keys(HistoryOrder.moved(rows, .node(.grid), to: 0)) == "grid,solar,home,battery,car")
        #expect(keys(HistoryOrder.moved(rows, .node(.solar), to: 2)) == "home,battery,solar,grid,car")
    }

    @Test func aPlaceOutsideTheListIsItsNearestEnd() {
        let rows = HistoryOrder.rows(stored: "", nodes: [.solar, .home, .grid], price: false)
        #expect(keys(HistoryOrder.moved(rows, .node(.solar), to: 9)) == "home,grid,solar")
        #expect(keys(HistoryOrder.moved(rows, .node(.grid), to: -3)) == "grid,solar,home")
    }

    @Test func aRowTheListHasNotGotMovesNothing() {
        let rows = HistoryOrder.rows(stored: "", nodes: [.solar, .home], price: false)
        #expect(HistoryOrder.moved(rows, .node(.car), to: 0) == rows)
        #expect(HistoryOrder.moved(rows, .price, to: 1) == rows)
    }

    @Test func aRowKnowsItsKeyBothWays() {
        for row in HistoryOrder.standard {
            #expect(HistoryRow(key: row.key) == row)
        }
        #expect(HistoryRow(key: "wind") == nil)
        #expect(HistoryRow(key: "") == nil)
    }
}
