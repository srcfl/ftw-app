import Foundation
import FTWShared

/// The grid's phases against the main fuse, from the box's extra fields 11
/// to 14.
///
/// Nil when the box sends no phase: a meter that gives none shows nothing,
/// never three idle meters. While the phases are not live the view keeps
/// their room and shows no number, because an old phase current says
/// nothing about the fuse now.
public struct GridPhases: Equatable, Sendable {
    public struct Phase: Equatable, Sendable {
        /// "L1", "L2", "L3".
        public let name: String
        /// The current's size in amps, nil while not live. The breaker
        /// trips on size, whichever way the current flows.
        public let amps: Double?
        /// The share of the fuse, nil while not live or with no fuse.
        public let ofFuse: Double?
    }

    public let phases: [Phase]
    /// The main fuse per phase, in amps.
    public let fuseA: Double?
    /// The phase nearest the fuse, by its place in `phases`, while live.
    public let nearest: Int?
    public let live: Bool

    public static func read(fields: [Int: Double], live: Bool) -> GridPhases? {
        let present = Contract.FID.gridPhases.enumerated().compactMap { i, fid in
            fields[fid].map { (name: "L\(i + 1)", deciamps: $0) }
        }
        guard !present.isEmpty else { return nil }
        let fuseA = fields[Contract.FID.gridFuseDA].flatMap { $0 > 0 ? $0 / 10 : nil }
        let phases = present.map { p -> Phase in
            guard live else { return Phase(name: p.name, amps: nil, ofFuse: nil) }
            let amps = abs(p.deciamps) / 10
            return Phase(name: p.name, amps: amps, ofFuse: fuseA.map { amps / $0 })
        }
        // The first of equals: max(by:) keeps the earliest maximum.
        let nearest = live && fuseA != nil ? phases.indices.max { (phases[$0].ofFuse ?? 0) < (phases[$1].ofFuse ?? 0) } : nil
        return GridPhases(phases: phases, fuseA: fuseA, nearest: nearest, live: live)
    }

    /// "PHASES · FUSE 20 A", the row's kicker.
    public var kicker: String {
        guard let fuseA else { return NodeWords.text("PHASES") }
        return NodeWords.format("PHASES · FUSE %@", Self.amps(fuseA, decimals: 0))
    }

    /// "6,0 A", or a dash while not live. The largest standard text size
    /// drops the decimal, "6 A", so three phases fit one line.
    public func reading(_ phase: Phase, decimals: Int = 1) -> String {
        phase.amps.map { Self.amps($0, decimals: decimals) } ?? "—"
    }

    /// One sentence for VoiceOver: each phase, which one is nearest the
    /// fuse, and the fuse.
    public var spoken: String {
        guard live else { return NodeWords.text("The phases are not live.") }
        let each = phases.enumerated().map { i, p in
            var s = p.name + " " + reading(p)
            if i == nearest { s += ", " + NodeWords.text("nearest the fuse") }
            return s
        }
        return each.joined(separator: "; ")
    }

    static func amps(_ a: Double, decimals: Int) -> String {
        AppWords.decimal(String(format: "%.\(decimals)f", a)) + "\u{00A0}A"
    }
}

extension SiteModel {
    /// The grid's phases as the node view draws them, live by the site
    /// meter's own freshness: the phases are its readings.
    public var gridPhases: GridPhases? {
        let fields = session.fields
        guard let fid = Contract.FID.gridPhases.first(where: { fields[$0] != nil }) else { return nil }
        return GridPhases.read(fields: fields, live: freshness(fid: fid).live)
    }
}
