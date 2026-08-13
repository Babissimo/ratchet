// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ratchet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RatchetCore"),
        .target(name: "FreeAgentKit", dependencies: ["RatchetCore"]),
        .executableTarget(name: "Ratchet", dependencies: ["RatchetCore", "FreeAgentKit"]),
        .executableTarget(name: "IconExporter", dependencies: ["RatchetCore"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
        .testTarget(name: "FreeAgentKitTests", dependencies: ["FreeAgentKit"]),
    ]
)
