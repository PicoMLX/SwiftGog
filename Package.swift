// swift-tools-version:6.2
import PackageDescription

// SwiftGog — a SwiftBash-native Google Workspace CLI (`gog`), ported from
// picomlx/gogcli. See PLAN.md for the full design.
//
// Dependency note: this uses a local path dependency on a sibling SwiftBash
// checkout so the package builds in the development environment (where all
// four repos are cloned side by side). For a standalone build, swap the
// `.package(path:)` line for:
//     .package(url: "https://github.com/picomlx/SwiftBash.git", branch: "main")
let package = Package(
    name: "SwiftGog",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GogCore", targets: ["GogCore"]),
        .library(name: "GogCommands", targets: ["GogCommands"]),
        .library(name: "GogShell", targets: ["GogShell"]),
    ],
    dependencies: [
        .package(path: "../SwiftBash"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // The engine: credential seam, runtime guards, version info.
        // (HTTP client / typed service clients land in Phase 0.)
        .target(
            name: "GogCore",
            dependencies: [
                .product(name: "BashInterpreter", package: "SwiftBash"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        // The ArgumentParser command tree (root `gog` + nested subcommands).
        .target(
            name: "GogCommands",
            dependencies: [
                "GogCore",
                .product(name: "BashInterpreter", package: "SwiftBash"),
                .product(name: "BashCommandKit", package: "SwiftBash"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        // One-call integration: `shell.registerGogCommands()`.
        .target(
            name: "GogShell",
            dependencies: [
                "GogCommands",
                .product(name: "BashInterpreter", package: "SwiftBash"),
                .product(name: "BashCommandKit", package: "SwiftBash"),
            ]),
        .testTarget(
            name: "GogShellTests",
            dependencies: [
                "GogShell", "GogCore", "GogCommands",
                .product(name: "BashInterpreter", package: "SwiftBash"),
            ]),
    ]
)
