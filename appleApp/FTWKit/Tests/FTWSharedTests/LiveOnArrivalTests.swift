import CoreGraphics
import FTWShared
import Testing

/// Traces fed by frames that come as readings land through FTW Cloud, up to
/// five a second, most of them carrying another device's news.
@Suite struct LiveOnArrivalTests {
    @Test func aRepeatedValueAddsAPointOnlyOnceASecond() {
        let last = LiveSample(t: 10_000, v: 1_200)
        #expect(!LiveSample.adds(LiveSample(t: 10_200, v: 1_200), after: last))
        #expect(LiveSample.adds(LiveSample(t: 10_200, v: 1_210), after: last))
        #expect(LiveSample.adds(LiveSample(t: 10_200, v: 1_200, seen: false), after: last))
        #expect(LiveSample.adds(LiveSample(t: 11_000, v: 1_200), after: last))
        #expect(!LiveSample.adds(LiveSample(t: 10_000, v: 1_300), after: last))
        #expect(LiveSample.adds(LiveSample(t: 0, v: 0), after: nil))
    }

    /// A reading that lands while the last one still slides starts its own
    /// slide where the head is drawn, never where the last slide was going.
    @Test func aReadingMidSlideSlidesOnFromWhereTheHeadIs() throws {
        let t0 = 1_000_000.0
        var samples = (0..<10).map { LiveSample(t: t0 + Double($0) * 1_000, v: 1_000 + Double($0 % 2) * 300) }
        func build(_ s: [LiveSample]) -> LiveSeries {
            LiveSeries.build(s, sourceGapMs: 3_500, windowMs: 300_000, nowMs: s.last!.t, size: CGSize(width: 300, height: 100), floor: 3_000)
        }
        let a = build(samples)
        samples.append(LiveSample(t: t0 + 10_000, v: 2_000))
        let b = build(samples)
        samples.append(LiveSample(t: t0 + 10_200, v: 500))
        let c = build(samples)
        try #require(a.domain == b.domain && b.domain == c.domain)

        let drawn = try #require(b.sliding(from: a, progress: 0.4)?.last)
        let start = try #require(c.sliding(from: b.midSlide(from: a, progress: 0.4), progress: 0)?.last)
        #expect(abs(start.t - drawn.t) < 0.001 && abs(start.v - drawn.v) < 0.001)

        // From the last slide's end instead, the head would jump.
        let jump = try #require(c.sliding(from: b, progress: 0)?.last)
        #expect(abs(jump.v - drawn.v) > 1)
    }
}
