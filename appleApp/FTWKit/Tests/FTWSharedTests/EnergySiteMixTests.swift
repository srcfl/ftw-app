import CoreGraphics
import Testing
@testable import FTWShared

@Suite("Site color proportions")
struct EnergySiteMixTests {
    @Test func adjoiningColorsFollowPowerAcrossSolarImportAndBatterySupply() {
        for powers in [[4.2, 1.2, 1.6, 1, 0.4], [0, 1.4, 3.2, 0, 4.6], [0, 0.8, 0.5, -1.3, 0]] {
            let mix = EnergySiteMix(powers: powers)
            var measured = Array(repeating: 0.0, count: 5)
            for y in 0..<60 {
                for x in 0..<36 {
                    let w = mix.weights(at: CGPoint(x: (Double(x) + 0.5) / 36, y: (Double(y) + 0.5) / 60))
                    #expect(abs(w.reduce(0, +) - 1) < 0.000001)
                    for i in 0..<5 { measured[i] += w[i] / 2160 }
                }
            }
            for i in 0..<5 { #expect(abs(measured[i] - mix.shares[i]) < 0.012) }
            let strongest = powers.indices.max { abs(powers[$0]) < abs(powers[$1]) }!
            #expect(measured[strongest] == measured.max())
            #expect(mix.shares[3] >= 0.035)
        }
    }

    @Test func missingAndExtremeReadingsKeepTheMixtureFinite() {
        for powers in [[], [Double.nan, .infinity], [1e308, 1e308, 0, 0, 0]] {
            let mix = EnergySiteMix(powers: powers)
            #expect(mix.biases.allSatisfy { $0.isFinite })
            #expect(abs(mix.shares.reduce(0, +) - 1) < 0.000001)
        }
    }
}
