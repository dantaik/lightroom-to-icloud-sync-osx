// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LightroomSync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LightroomSync", targets: ["LightroomSync"]),
        .executable(name: "lrsync-check", targets: ["lrsync-check"]),
        .executable(name: "lrsync-local", targets: ["lrsync-local"]),
        .library(name: "LightroomSyncCore", targets: ["LightroomSyncCore"]),
    ],
    dependencies: [
        // SHA-256 for the content hash that identifies a photo by its picture alone.
        // Apple's own, and available on Linux too, where CryptoKit is not.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Platform-independent logic: share-link parsing, Lightroom gallery client,
        // sync policy, ledger. Builds and tests on Linux as well as macOS.
        .target(name: "LightroomSyncCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        // The macOS menu bar app (SwiftUI + PhotoKit). Only builds on macOS.
        .executableTarget(name: "LightroomSync", dependencies: ["LightroomSyncCore"]),
        // Command-line diagnostics: inspect a share link and optionally download its photos.
        .executableTarget(name: "lrsync-check", dependencies: ["LightroomSyncCore"]),
        // Command-line diagnostics: report what Lightroom's library on this Mac holds, and which
        // photo sizes it could serve without downloading.
        .executableTarget(name: "lrsync-local", dependencies: ["LightroomSyncCore"]),
        .testTarget(
            name: "LightroomSyncCoreTests",
            dependencies: ["LightroomSyncCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
