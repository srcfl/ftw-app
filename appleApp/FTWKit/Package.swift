// swift-tools-version:6.2
//
// Everything the iPhone app does that is not a pixel, in three modules:
//
// - FTWKit: pairing, the passkey derivations, Noise IK, frames, the relay,
//   the session and the state each screen reads. The app alone links it.
// - FTWShared: plain `Sendable` values the app shares with its widgets and,
//   later, a notification extension. The App Group cache, its records and
//   the formatters a widget needs. Nothing on the main actor, no keys.
// - FTWDemo: a simulated box in this process, for the demo, App Review and
//   previews. Kept out of FTWKit so the product module holds no fake box.
//
// CryptoKit provides the primitives. macOS is listed only so `swift test`
// runs on a Mac; the app itself is iPhone only.

import PackageDescription

let package = Package(
    name: "FTWKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "FTWKit", targets: ["FTWKit"]),
        .library(name: "FTWShared", targets: ["FTWShared"]),
        .library(name: "FTWDemo", targets: ["FTWDemo"]),
    ],
    targets: [
        .target(name: "FTWShared", resources: [.process("Resources")]),
        .target(name: "FTWKit", dependencies: ["FTWShared"]),
        .target(name: "FTWDemo", dependencies: ["FTWKit"]),
        .testTarget(
            name: "FTWKitTests",
            dependencies: ["FTWKit", "FTWDemo"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "FTWSharedTests", dependencies: ["FTWShared"]),
    ]
)
