// swift-tools-version:6.2
//
// Everything the iPhone app does that is not a pixel, in four modules:
//
// - FTWKit: pairing, the passkey derivations, the relay, the session and
//   the state each screen reads. The app alone links it.
// - FTWWire: the box's wire and nothing else. Noise IK, CBOR, frames, the
//   app-protocol messages and FTW Cloud's envelopes and freshness rules.
//   FTWKit re-exports it; the watch links it on its own.
// - FTWShared: plain `Sendable` values the app shares with its widgets and
//   its notification extension. The App Group cache, its records, the
//   formatters a widget needs, and the check and the words of a push.
//   Nothing on the main actor, no secret keys.
// - FTWDemo: a simulated box in this process, for the demo, App Review and
//   previews. Kept out of FTWKit so the product module holds no fake box.
//
// CryptoKit provides the primitives. macOS is listed only so `swift test`
// runs on a Mac; the app itself is iPhone only.

import PackageDescription

let package = Package(
    name: "FTWKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "FTWKit", targets: ["FTWKit"]),
        .library(name: "FTWShared", targets: ["FTWShared"]),
        .library(name: "FTWWire", targets: ["FTWWire"]),
        .library(name: "FTWDemo", targets: ["FTWDemo"]),
    ],
    targets: [
        .target(name: "FTWShared", resources: [.process("Resources")]),
        .target(name: "FTWWire", dependencies: ["FTWShared"]),
        .target(name: "FTWKit", dependencies: ["FTWShared", "FTWWire"]),
        .target(name: "FTWDemo", dependencies: ["FTWKit"]),
        .testTarget(
            name: "FTWKitTests",
            dependencies: ["FTWKit", "FTWWire", "FTWDemo"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "FTWSharedTests",
            dependencies: ["FTWShared"],
            resources: [.copy("Resources")]
        ),
    ]
)
