// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Ratchet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RatchetCore"),
        .target(name: "FreeAgentKit", dependencies: ["RatchetCore"]),
        .executableTarget(name: "Ratchet", dependencies: ["RatchetCore", "FreeAgentKit"]),
        // Dev-only renderer, never shipped in the bundle — build it explicitly (as
        // scripts/build-app.sh does) rather than pulling it into a plain `swift build`.
        .executableTarget(name: "IconExporter", dependencies: ["RatchetCore"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
        .testTarget(name: "FreeAgentKitTests", dependencies: ["FreeAgentKit"]),
    ]
)
