import Foundation

// The bulk-lane answers history arrives in: `hist.query`, `hist.chunk` and
// `hist.end`. Shapes from ftw-webapp docs/protocol.md and the box's
// go/protocol/messages.go. FTW Cloud's tiles carry the same chunk.
//
// Every decoder ignores keys it does not know and defaults what an older box
// leaves out.

// MARK: - History

/// The stores the box keeps, named as the registry's `resolutions` names them.
public enum Resolution: String, Sendable, CaseIterable {
    case fiveMinutes = "5m"
    case hour = "1h"
}

/// A hole on the wire. Distinct from zero, which is a real reading.
public let missingSample = Int32.min

public struct HistQuery: Sendable {
    /// Registry field names, such as `pv_w`.
    public var series: [String]
    public var res: Resolution
    /// Wall clock: these are hours a person reads.
    public var fromMs: Double
    public var toMs: Double
    /// Tiles already held, so the box sends only what changed.
    public var have: [(tileId: String, etag: String)]
    public var maxPoints: Int?

    public init(series: [String], res: Resolution, fromMs: Double, toMs: Double, have: [(tileId: String, etag: String)] = [], maxPoints: Int? = nil) {
        self.series = series
        self.res = res
        self.fromMs = fromMs
        self.toMs = toMs
        self.have = have
        self.maxPoints = maxPoints
    }

    package var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("series", .array(series.map { .text($0) })),
            ("res", .text(res.rawValue)),
            // Whole milliseconds: the box reads these into int64 and drops a
            // query whose times carry a fraction.
            ("fromMs", .ms(fromMs)),
            ("toMs", .ms(toMs)),
        ]
        if !have.isEmpty {
            pairs.append(("have", .array(have.map { .map([("tileId", .text($0.tileId)), ("etag", .text($0.etag))]) })))
        }
        if let maxPoints { pairs.append(("maxPoints", .int(maxPoints))) }
        return .map(pairs)
    }
}

/// One tile: evenly spaced samples from `startMs`, one int32 column per
/// series. Mean watts over each step, site-signed.
public struct HistChunk: Sendable, Equatable {
    public var tileId: String
    public var etag: String
    public var res: Resolution
    public var startMs: Double
    public var stepMs: Double
    public var series: [String]
    /// Column-packed int32 little-endian, one block per series.
    public var data: Bytes
    /// The trailing tile is still filling; never kept.
    public var partial: Bool

    public init(tileId: String, etag: String, res: Resolution, startMs: Double, stepMs: Double, series: [String], data: Bytes, partial: Bool) {
        self.tileId = tileId
        self.etag = etag
        self.res = res
        self.startMs = startMs
        self.stepMs = stepMs
        self.series = series
        self.data = data
        self.partial = partial
    }

    package init?(_ c: CBOR) {
        guard let tileId = c["tileId"]?.string else { return nil }
        self.tileId = tileId
        etag = c["etag"]?.string ?? ""
        res = c["res"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        startMs = c["startMs"]?.double ?? 0
        stepMs = c["stepMs"]?.double ?? 300_000
        series = c["series"]?.stringArray ?? []
        data = c["data"]?.byteString ?? []
        partial = c["partial"]?.bool ?? false
    }

    package var cbor: CBOR {
        .map([
            ("tileId", .text(tileId)), ("etag", .text(etag)), ("res", .text(res.rawValue)),
            ("startMs", .ms(startMs)), ("stepMs", .ms(stepMs)),
            ("series", .array(series.map { .text($0) })), ("data", .bytes(data)), ("partial", .bool(partial)),
        ])
    }
}

public struct HistGap: Equatable, Sendable {
    public var fromMs: Double
    public var toMs: Double
    public var reason: String
}

public struct HistEnd: Sendable, Equatable {
    /// What the box actually served, which may be coarser than asked for.
    public var resActual: Resolution
    public var gaps: [HistGap]

    package init(_ c: CBOR) {
        resActual = c["resActual"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        gaps = (c["gaps"]?.array ?? []).compactMap { g in
            guard let from = g["fromMs"]?.double, let to = g["toMs"]?.double else { return nil }
            return HistGap(fromMs: from, toMs: to, reason: g["reason"]?.string ?? "no_data")
        }
    }
}

extension HistQuery {
    /// The query as the box reads it, for the simulated box.
    public init?(cbor c: CBOR) {
        guard let res = c["res"]?.string.flatMap(Resolution.init(rawValue:)),
              let from = c["fromMs"]?.double, let to = c["toMs"]?.double else { return nil }
        self.init(
            series: c["series"]?.stringArray ?? [],
            res: res,
            fromMs: from,
            toMs: to,
            have: (c["have"]?.array ?? []).compactMap { h in
                guard let id = h["tileId"]?.string, let etag = h["etag"]?.string else { return nil }
                return (id, etag)
            },
            maxPoints: c["maxPoints"]?.int
        )
    }
}

extension HistChunk {
    /// The tile as it goes on the wire, for the simulated box.
    public var wire: CBOR { cbor }
}

extension HistEnd {
    public init(resActual: Resolution, gaps: [HistGap]) {
        self.resActual = resActual
        self.gaps = gaps
    }

    /// The end as it goes on the wire, for the simulated box.
    public var wire: CBOR {
        .map([
            ("resActual", .text(resActual.rawValue)),
            ("gaps", .array(gaps.map { .map([("fromMs", .ms($0.fromMs)), ("toMs", .ms($0.toMs)), ("reason", .text($0.reason))]) })),
        ])
    }
}
