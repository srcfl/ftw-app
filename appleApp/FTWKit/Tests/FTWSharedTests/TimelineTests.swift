import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

@Suite struct TimelineTests {
    static let now = 1_800_000_000_000.0

    @Test func aPanKeepsTheTimeUnderTheMovingFinger() {
        let original = TimelineWindow(nowMs: Self.now)
        let next = original.transformed(anchor: 0.25, destination: 0.75, magnification: 1, nowMs: Self.now)
        #expect(next.time(at: 0.75) == original.time(at: 0.25))
        #expect(!next.followsNow)
    }

    @Test func aPinchKeepsItsCentroidTimeWhileItMoves() {
        let original = TimelineWindow(nowMs: Self.now)
        let next = original.transformed(anchor: 0.3, destination: 0.6, magnification: 2, nowMs: Self.now)
        #expect(next.spanMs == original.spanMs / 2)
        #expect(next.time(at: 0.6) == original.time(at: 0.3))
    }

    @Test func readingsAndLateHistoryAnswersCannotMoveAPannedWindow() {
        var window = TimelineWindow(nowMs: Self.now).transformed(anchor: 0, destination: 0.5, magnification: 1, nowMs: Self.now)
        let held = window
        window.follow(nowMs: Self.now + 120_000)
        #expect(window == held)
        window.returnToNow(nowMs: Self.now + 120_000)
        #expect(window.followsNow)
        #expect(window.time(at: TimelineWindow.nowPosition) == Self.now + 120_000)
    }

    @Test func theAvailablePastAndZoomAreBounded() {
        let initial = TimelineWindow(nowMs: Self.now)
        let oldest = initial.transformed(anchor: 0, destination: 1_000, magnification: 0.0001, nowMs: Self.now)
        #expect(oldest.fromMs == Self.now - TimelineWindow.historyMs)
        #expect(oldest.spanMs == TimelineWindow.maximumSpanMs)
        let closest = initial.transformed(anchor: 0.5, destination: 0.5, magnification: 1_000, nowMs: Self.now)
        #expect(closest.spanMs == TimelineWindow.minimumSpanMs)
        let future = initial.transformed(anchor: 0, destination: -1_000, magnification: 1, nowMs: Self.now)
        #expect(future.toMs == Self.now + TimelineWindow.aheadMs)
        #expect(!future.followsNow)
        #expect(initial.transformed(anchor: .nan, destination: 0, magnification: 1, nowMs: Self.now) == initial)
    }

    @Test func elapsedTimeAndTheFingerStayCorrectAcrossBothClockChanges() throws {
        let clock = ZoneClock.of(try #require(TimeZone(identifier: "Europe/Stockholm")))
        for parts in [DateComponents(year: 2026, month: 3, day: 29, hour: 4), DateComponents(year: 2026, month: 10, day: 25, hour: 4)] {
            let now = try #require(clock.calendar.date(from: parts)).timeIntervalSince1970 * 1000
            let window = TimelineWindow(nowMs: now, spanMs: 6 * 3_600_000)
            let zoomed = window.transformed(anchor: 0.4, destination: 0.6, magnification: 2, nowMs: now)
            #expect(zoomed.time(at: 0.6) == window.time(at: 0.4))
            #expect(zoomed.spanMs == 3 * 3_600_000)
        }
    }

    @Test func aSourceObservationWinsWithoutRewritingTheStoredMean() {
        let history = [ChartSample(startMs: 0, value: 1_000)]
        let observation = LiveSample(t: 210_000, v: 4_000)
        #expect(TimelineReading.at(210_100, history: history, observations: [observation], gapMs: 3_500, nowMs: 240_000) == .observation(atMs: 210_000, watts: 4_000, seen: true))
        #expect(history == [ChartSample(startMs: 0, value: 1_000)])
        #expect(TimelineReading.at(30_000, history: history, observations: [observation], gapMs: 3_500, nowMs: 300_000) == .mean(startMs: 0, endMs: 300_000, watts: 1_000))
    }

    @Test func aConfirmedHoleIsNeitherZeroNorAnInterpolatedReading() {
        let history = [ChartSample(startMs: 0, value: nil), ChartSample(startMs: 300_000, value: 0)]
        let observations = [LiveSample(t: 20_000, v: 1_000), LiveSample(t: 40_000, v: 3_000)]
        #expect(TimelineReading.at(30_000, history: history, observations: observations, gapMs: 3_500, nowMs: 600_000) == .missing)
        #expect(TimelineReading.at(310_000, history: history, observations: [], gapMs: 3_500, nowMs: 600_000) == .mean(startMs: 300_000, endMs: 600_000, watts: 0))
        #expect(TimelineReading.at(30_000, history: [.init(startMs: 0, value: nil, fetching: true)], observations: [], gapMs: 3_500, nowMs: 600_000) == .fetching)
    }

    @Test func restoredPointsStaySavedAndFuturePointsAreNeverReadAsLive() {
        let observations = [LiveSample(t: 20_000, v: 1_000, seen: false), LiveSample(t: 40_000, v: 3_000)]
        #expect(TimelineReading.at(20_000, history: [], observations: observations, gapMs: 3_500, nowMs: 30_000) == .observation(atMs: 20_000, watts: 1_000, seen: false))
        #expect(TimelineReading.at(40_000, history: [], observations: observations, gapMs: 3_500, nowMs: 30_000) == .missing)
    }

    @Test func theFutureIsExplicitAndCannotReplaceTheMeasuredPast() {
        let marks = [AheadPicture.Mark(startMs: 0, endMs: 3_600_000, watts: 5_000)]
        let history = [ChartSample(startMs: 0, value: 1_000)]
        #expect(TimelineReading.at(150_000, history: history, observations: [], gapMs: 3_500, nowMs: 300_000, ahead: (.forecast, marks)) == .mean(startMs: 0, endMs: 300_000, watts: 1_000))
        #expect(TimelineReading.at(400_000, history: history, observations: [], gapMs: 3_500, nowMs: 300_000, ahead: (.forecast, marks)) == .forecast(startMs: 300_000, endMs: 3_600_000, watts: 5_000))
        #expect(TimelineReading.at(400_000, history: history, observations: [], gapMs: 3_500, nowMs: 300_000, ahead: (.plan, marks)) == .plan(startMs: 300_000, endMs: 3_600_000, watts: 5_000))
    }

    @Test func livePeaksFitWithoutChangingTheHistorysValuesOrEnergy() {
        let history = [ChartSample(startMs: 0, value: 1_000), ChartSample(startMs: 300_000, value: 2_000)]
        let words = ReadoutWords(value: { String($0) }, range: { "\($0)–\($1)" }, none: "no data")
        let a = HistoryPicture.build([("home", history)], fromMs: 0, toMs: 600_000, nowMs: 600_000, size: .init(width: 350, height: 200), clock: .of(.gmt), words: words)
        let b = HistoryPicture.build([("home", history)], fromMs: 0, toMs: 600_000, nowMs: 600_000, size: .init(width: 350, height: 200), clock: .of(.gmt), observationExtent: 0...8_000, words: words)
        #expect(b.domain.upper >= 8_000)
        #expect(a.layers[0].series.readouts.inWh == b.layers[0].series.readouts.inWh)
        #expect(a.layers[0].series.buckets.map(\.mean) == b.layers[0].series.buckets.map(\.mean))
    }

    @Test func anHourlyLedgerMeanIsNotTwelveFiveMinuteObservations() {
        let words = ReadoutWords(value: { String($0) }, range: { "\($0)–\($1)" }, none: "no data")
        let picture = HistoryPicture.build([("car", [ChartSample(startMs: 0, value: 3_000)])], fromMs: 0, toMs: 3_600_000, nowMs: 3_600_000, size: .init(width: 350, height: 200), clock: .of(.gmt), sampleSteps: ["car": 3_600_000], words: words)
        #expect(picture.grid.stepMs == 3_600_000)
        #expect(picture.layers[0].series.buckets.count == 1)
        #expect(picture.layers[0].series.buckets[0].count == 1)
        #expect(picture.layers[0].series.readouts.inWh.last == 3_000)
    }
    @Test func onePointDoesNotHideHistoryAndSourceSilencesStayUncovered() {
        func series(_ points: [LiveSample]) -> LiveSeries {
            LiveSeries.build(points, sourceGapMs: 3_500, periodMs: 1_000, windowMs: 300_000, nowMs: 300_000, size: .init(width: 350, height: 200))
        }
        #expect(series([.init(t: 100_000, v: 2_000)]).observedRanges.isEmpty)
        let runs = series([.init(t: 100_000, v: 2_000), .init(t: 101_000, v: 2_100), .init(t: 200_000, v: 1_000), .init(t: 201_000, v: 900)])
        #expect(runs.observedRanges == [100_000...101_000, 200_000...201_000])
    }

    @Test func visibleEnergyClipsThePastAndNeverIncludesFutureOrLiveTwice() {
        let samples = [ChartSample(startMs: 0, value: 1_200), ChartSample(startMs: 300_000, value: nil), ChartSample(startMs: 600_000, value: 9_000)]
        let energy = TimelineEnergy.recorded(samples, fromMs: 150_000, toMs: 900_000, nowMs: 600_000)
        #expect(energy.inWh == 50)
        #expect(energy.knownMs == 150_000)
        #expect(energy.missingMs == 300_000)
        #expect(energy.prorated)
        let future = TimelineEnergy.recorded(samples, fromMs: 600_000, toMs: 900_000, nowMs: 600_000)
        #expect(future.inWh == 0 && future.knownMs == 0 && future.missingMs == 0)
    }

    @Test func allMissingIsUnknownButARecordedZeroIsKnown() {
        let absent = TimelineEnergy.recorded([.init(startMs: 0, value: nil)], fromMs: 0, toMs: 300_000, nowMs: 300_000)
        #expect(absent.knownMs == 0 && absent.missingMs == 300_000)
        let pending = TimelineEnergy.recorded([.init(startMs: 0, value: nil, fetching: true)], fromMs: 0, toMs: 300_000, nowMs: 300_000)
        #expect(pending.knownMs == 0 && pending.missingMs == 0 && pending.fetchingMs == 300_000)
        let zero = TimelineEnergy.recorded([.init(startMs: 0, value: 0)], fromMs: 0, toMs: 300_000, nowMs: 300_000)
        #expect(zero.inWh == 0 && zero.knownMs == 300_000 && zero.missingMs == 0)
    }

    @Test func anOpenBucketsSmallMeanDoesNotPretendTheLiveLoadFellToZero() {
        // Energy recorded during the first second, divided by the whole
        // five-minute bucket, can round near zero while power is 3 kW.
        let partial = [ChartSample(startMs: 300_000, value: 10)]
        #expect(TimelineReading.at(300_500, history: partial, observations: [], gapMs: 3_500, nowMs: 301_000) == .fetching)
        #expect(TimelineReading.at(300_500, history: partial, observations: [.init(t: 300_500, v: 3_000)], gapMs: 3_500, nowMs: 301_000) == .observation(atMs: 300_500, watts: 3_000, seen: true))
        let energy = TimelineEnergy.recorded(partial, fromMs: 300_000, toMs: 600_000, nowMs: 301_000)
        #expect(energy.knownMs == 0 && energy.inWh == 0 && energy.fetchingMs == 1_000 && energy.missingMs == 0)
        #expect(TimelineReading.at(300_500, history: partial, observations: [], gapMs: 3_500, nowMs: 600_000) == .mean(startMs: 300_000, endMs: 600_000, watts: 10))
    }

    @Test func aShortFutureViewportKeepsItsHourlyForecastAndClipsItAtNow() {
        let domain = YDomain(lower: 0, upper: 4_000)
        let marks = [AheadPicture.Mark(startMs: 0, endMs: 3_600_000, watts: 2_000)]
        let path = AheadPicture.forecastLine(marks, fromMs: 1_800_000, toMs: 2_400_000, domain: domain, size: .init(width: 300, height: 100), intervalMeans: true, notBeforeMs: 2_100_000)
        #expect(path.elements == [.move(.init(x: 150, y: 50)), .line(.init(x: 300, y: 50))])
        let beforeNow = AheadPicture.forecastLine(marks, fromMs: 1_800_000, toMs: 2_000_000, domain: domain, size: .init(width: 300, height: 100), intervalMeans: true, notBeforeMs: 2_100_000)
        #expect(beforeNow.isEmpty)
    }

    @Test func aFutureWindowScalesOnlyItsVisiblePlan() {
        let marks = [AheadPicture.Mark(startMs: 0, endMs: 3_600_000, watts: 20_000),
                     AheadPicture.Mark(startMs: 3_600_000, endMs: 7_200_000, watts: 1_000)]
        let picture = HistoryPicture.build([("home", [])], ahead: ["home": (.plan, marks)],
            fromMs: 3_600_000, toMs: 7_200_000, nowMs: 0, size: .init(width: 300, height: 100),
            clock: .of(TimeZone(secondsFromGMT: 0)!), words: ReadoutWords(value: { "\($0)" }, range: { "\($0)–\($1)" }, none: "none"))
        #expect(picture.domain.upper < 20_000)
        #expect(picture.domain.upper >= 1_000)
    }

}
