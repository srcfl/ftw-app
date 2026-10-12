import Foundation
import Testing
@testable import FTWKit
import FTWDemo

/// The registry is one file shared with the box and the web app. Every name
/// this app spells has to be the registry's. `Contract` is written by hand,
/// the way the web app writes its own, and this is what keeps it honest.
@Suite struct ContractTests {
    let yaml: String

    init() throws {
        yaml = try RepoFiles.read("protocol/registry.yaml")
    }

    /// Lines of one top-level section, without comments.
    func section(_ name: String) -> [Substring] {
        var out = [Substring]()
        var inside = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\(name):") { inside = true; continue }
            if inside, let first = line.first, !first.isWhitespace, first != "#" { break }
            if inside, !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { out.append(line) }
        }
        return out
    }

    /// The value after `key: ` on every line of a section that has one.
    func values(_ section: String, _ key: String) -> [String] {
        self.section(section).compactMap { line in
            guard let range = line.range(of: "\(key): ") else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "," && $0 != "}" && $0 != " " })
        }
    }

    func list(_ section: String) -> [String] {
        self.section(section).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") ? String(t.dropFirst(2)) : nil
        }
    }

    @Test func namesMatchTheSharedRegistry() {
        #expect(values("scopes", "name") == Contract.scopes)
        #expect(values("ops", "name") == Contract.ops)
        #expect(list("capabilities") == Contract.capabilities)
        #expect(values("modes", "key") == Contract.modes.map(\.key))
        #expect(values("modes", "tier") == Contract.modes.map(\.tier))
        let errors = values("errors", "code") + values("client_errors", "code")
        #expect(Set(errors) == Set(Contract.retryable.keys))
        for code in errors {
            let line = yaml.split(separator: "\n").first { $0.contains("code: \(code),") }!
            #expect(line.contains("retryable: \(Contract.isRetryable(code))"), "\(code)")
        }
        #expect(yaml.contains("source_states: [\(Contract.sourceStates.joined(separator: ", "))]"))
        #expect(yaml.contains("carrier_states: [\(Contract.carrierStates.joined(separator: ", "))]"))
    }

    /// FTWShared spells the same states as enums, for widgets that never
    /// link FTWKit.
    @Test func sharedStatesAreTheRegistrys() {
        #expect([CarrierKind.webrtc, .relay, .cloud, .cache, .none].map(\.rawValue) == Contract.carrierStates)
        #expect([SourceState.live, .lagging, .stale, .down, .never].map(\.rawValue) == Contract.sourceStates)
        #expect(Contract.sourceStates.allSatisfy { SourceState(rawValue: $0) != nil })
        #expect(Contract.carrierStates.allSatisfy { CarrierKind(rawValue: $0) != nil })
    }

    @Test func frozenFieldIDsAreTheRegistrys() {
        typealias F = Contract.FID
        let ids: [(Int, String)] = [
            (F.mode, "mode"), (F.gridW, "grid_w"), (F.pvW, "pv_w"), (F.batteryW, "battery_w"),
            (F.batterySoc, "battery_soc"), (F.loadW, "load_w"), (F.srcGrid, "src_grid"),
            (F.srcPV, "src_pv"), (F.srcBattery, "src_battery"), (F.evW, "ev_w"),
        ]
        let frozen = section("frozen_fields").filter { $0.contains("{ name:") }
        #expect(frozen.count == ids.count)
        for (id, name) in ids {
            #expect(frozen.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(id): { name: \(name),") }, "\(id) \(name)")
        }
    }

    /// The demo box is not the box, but it may not invent the box's names.
    @Test func theDemoBoxSpeaksOnlyRegistryNames() {
        let modes = Set(Contract.modes.map(\.key))
        #expect(SimulatedBox.modes.allSatisfy { modes.contains($0.key) })
        #expect(SimulatedBox.modes.allSatisfy { m in Contract.modes.first { $0.key == m.key }?.tier == m.tier })
        #expect(Set(SimulatedBox.caps).isSubset(of: Contract.capabilities))
    }
}
