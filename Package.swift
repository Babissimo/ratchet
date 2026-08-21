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
        // Dev-only regression harness for the local/remote state divergences fixed in
        // cbcb28f..64853c6. It lives here rather than in Tests/ because `swift test` cannot run
        // on a machine without Xcode (see CLAUDE.md) — as an executable it is the only
        // *runnable* evidence those bugs stay fixed. Never shipped in the bundle.
        .executableTarget(name: "Antagonise", dependencies: ["RatchetCore", "FreeAgentKit"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
        .testTarget(name: "FreeAgentKitTests", dependencies: ["FreeAgentKit"]),
    ]
)
