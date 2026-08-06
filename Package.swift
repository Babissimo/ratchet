// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ratchet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RatchetCore"),
        .executableTarget(name: "Ratchet", dependencies: ["RatchetCore"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
    ]
)
