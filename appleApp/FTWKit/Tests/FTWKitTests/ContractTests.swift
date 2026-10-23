import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire
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
        #expect(yaml.contains("cloud_transports: [\(Contract.cloudTransports.joined(separator: ", "))]"))
        #expect(Contract.cloudTransports == [Contract.transportQUIC, Contract.transportWebSocket])
    }

    /// The car's names, before the app draws a car.
    @Test func carNamesAreTheRegistrys() {
        #expect(values("car_fields", "name") == Contract.carFields)
        #expect(values("charger_car_fields", "name") == Contract.chargerCarFields)
        #expect(yaml.contains("car_soc_sources: [\(Contract.carSocSources.joined(separator: ", "))]"))
        #expect(yaml.contains("car_identified_by: [\(Contract.carIdentifiedBy.joined(separator: ", "))]"))
    }

    /// The agents' names (docs/agents.md in srcfl/ftw): what each role may
    /// carry, which scope opens each op, and what an agent may put in it,
    /// with the label an owner reads.
    @Test func agentNamesAreTheRegistrys() {
        let roles = section("roles")
        for role in [Contract.roleAgent, Contract.roleSupport, Contract.roleRelease] {
            let start = roles.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "\(role):" }!
            let label = roles[roles.index(after: start)].trimmingCharacters(in: .whitespaces)
            let scopes = roles[roles.index(start, offsetBy: 2)].trimmingCharacters(in: .whitespaces)
            #expect(label == "label: \(Contract.roleLabels[role]!)", "\(role)")
            #expect(scopes == "scopes: [\(Contract.agentRoleScopes[role]!.joined(separator: ", "))]", "\(role)")
        }
        for line in section("scopes") where line.contains("{ name:") {
            let name = values("scopes", "name").first { line.contains("name: \($0),") }!
            #expect(line.contains("desc: \(Contract.scopeDescs[name]!) }"), "\(name)")
        }
        #expect(Set(Contract.scopeDescs.keys) == Set(Contract.scopes))
        var agentOps = [String: String]()
        for line in section("ops") where line.contains("{ name:") {
            let name = String(line.split(separator: "name: ")[1].prefix { $0 != "," })
            #expect(line.contains("desc: \(Contract.opDescs[name]!) }"), "\(name)")
            if let r = line.range(of: "agent: ") { agentOps[name] = String(line[r.upperBound...].prefix { $0 != "," }) }
        }
        #expect(agentOps == Contract.agentOps)
        // agent_args: an op's name on its own line, then one line per argument.
        var args = [String: [Contract.AgentArg]]()
        var op = ""
        for line in section("agent_args") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(":"), !t.hasPrefix("-") { op = String(t.dropLast()); continue }
            guard t.hasPrefix("- {") else { continue }
            let body = t.dropFirst(3).dropLast(1).trimmingCharacters(in: .whitespaces)
            var fields = [String: String]()
            var rest = Substring(body)
            while let colon = rest.range(of: ": ") {
                let key = rest[..<colon.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                rest = rest[colon.upperBound...]
                if key == "label" {
                    fields[key] = rest.trimmingCharacters(in: .whitespaces)
                    break
                }
                if rest.hasPrefix("[") {
                    let end = rest.firstIndex(of: "]")!
                    fields[key] = String(rest[rest.index(after: rest.startIndex)..<end])
                    rest = rest[rest.index(after: end)...]
                } else {
                    let end = rest.firstIndex(of: ",") ?? rest.endIndex
                    fields[key] = String(rest[..<end])
                    rest = rest[end...]
                }
            }
            args[op, default: []].append(Contract.AgentArg(
                fields["name"]!, fields["kind"]!, unit: fields["unit"], min: fields["min"].flatMap(Double.init),
                max: fields["max"].flatMap(Double.init),
                values: fields["values"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
                required: fields["required"] == "true", cap: fields["cap"], label: fields["label"]!
            ))
        }
        #expect(args == Contract.agentArgs)
        #expect(Set(args.keys).isSubset(of: Set(Contract.agentOps.keys)))
        #expect(list("capabilities").contains(Contract.capAccessAgents))
    }

    /// FTWShared spells the same states as enums, for widgets that never
    /// link FTWKit.
    @Test func sharedStatesAreTheRegistrys() {
        #expect([CarrierKind.webrtc, .relay, .tunnel, .cloud, .cache, .none].map(\.rawValue) == Contract.carrierStates)
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

    @Test func extraFieldIDsAreTheRegistrys() {
        typealias F = Contract.FID
        let ids: [(Int, String)] = [
            (F.gridL1DA, "grid_l1_da"), (F.gridL2DA, "grid_l2_da"), (F.gridL3DA, "grid_l3_da"),
            (F.gridFuseDA, "grid_fuse_da"),
        ]
        let extra = section("extra_fields").filter { $0.contains("{ name:") }
        #expect(extra.count == ids.count)
        for (id, name) in ids {
            #expect(extra.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(id): { name: \(name),") }, "\(id) \(name)")
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
