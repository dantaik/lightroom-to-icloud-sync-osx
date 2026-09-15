// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LightroomSync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LightroomSync", targets: ["LightroomSync"]),
        .executable(name: "lrsync-check", targets: ["lrsync-check"]),
        .library(name: "LightroomSyncCore", targets: ["LightroomSyncCore"]),
    ],
    targets: [
        // Platform-independent logic: share-link parsing, Lightroom gallery client,
        // sync policy, ledger. Builds and tests on Linux as well as macOS.
        .target(name: "LightroomSyncCore"),
        // The macOS menu bar app (SwiftUI + PhotoKit). Only builds on macOS.
        .executableTarget(name: "LightroomSync", dependencies: ["LightroomSyncCore"]),
        // Command-line diagnostics: inspect a share link and optionally download its photos.
        .executableTarget(name: "lrsync-check", dependencies: ["LightroomSyncCore"]),
        .testTarget(
            name: "LightroomSyncCoreTests",
            dependencies: ["LightroomSyncCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
