// swift-tools-version:6.0
//
// FTWKit: everything the native app does that is not a pixel. Pairing, the
// passkey derivations, Noise IK, frames, the relay, the session and the
// state each screen reads. The SwiftUI app in ../FTW is a thin layer over it.
//
// It builds and tests on Linux as well as on Apple platforms, so the
// protocol can be checked anywhere Swift runs. CryptoKit provides the
// primitives on Apple platforms; swift-crypto provides the same API on
// Linux and is linked nowhere else.

import PackageDescription

let package = Package(
    name: "FTWKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FTWKit", targets: ["FTWKit"]),
    ],
    dependencies: [
        // Below 5, whose manifest needs Swift 6.2: Xcode 16 must still
        // resolve this package even though it links it nowhere.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "FTWKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "FTWKitTests",
            dependencies: ["FTWKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
