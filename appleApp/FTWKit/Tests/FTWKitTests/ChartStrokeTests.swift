import Foundation
import Testing
@testable import FTWKit

/// Every stroke in `FTWCharts` joins round. SwiftUI joins with a miter by
/// default, and on a polyline a sharp turn then draws a point past the data:
/// 4.8 pt beyond the vertex for a 2.5 pt stroke turning 30°.
@Suite struct ChartStrokeTests {
    static let folder = "appleApp/FTWCharts"

    static func sources() throws -> [(name: String, text: String)] {
        let dir = RepoFiles.root.appendingPathComponent(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try RepoFiles.read("\(folder)/\($0)")) }
    }

    /// The text of each call that opens at `open`, up to its closing
    /// parenthesis.
    static func calls(_ open: String, in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let r = rest.range(of: open) {
            var depth = 1, i = r.upperBound
            while i < rest.endIndex, depth > 0 {
                if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }
                i = rest.index(after: i)
            }
            out.append(String(rest[r.lowerBound..<i]))
            rest = rest[i...]
        }
        return out
    }

    @Test func everyStrokeStyleJoinsRound() throws {
        var styles = 0
        for (name, text) in try Self.sources() {
            for call in Self.calls("StrokeStyle(", in: text) {
                styles += 1
                #expect(call.contains("lineJoin: .round"), "\(name): \(call)")
            }
            // A bare width falls back to the miter join.
            for call in Self.calls(".stroke(", in: text) + Self.calls(".strokeBorder(", in: text) {
                #expect(!call.contains("lineWidth:") || call.contains("StrokeStyle("), "\(name): \(call)")
            }
        }
        #expect(styles > 0, "no StrokeStyle found in \(Self.folder)")
    }

    @Test func eachNodeHasAScaleFloorAndARatingTakesItsPlace() {
        #expect(EnergyNode.home.scaleFloorW() == 2_000)
        #expect(EnergyNode.grid.scaleFloorW() == 3_000)
        #expect(EnergyNode.allCases.allSatisfy { $0.scaleFloorW() >= 2_000 })
        #expect(EnergyNode.car.scaleFloorW(rating: 11_000) == 11_000)
        #expect(EnergyNode.battery.scaleFloorW(rating: .nan) == 3_000)
    }
}
