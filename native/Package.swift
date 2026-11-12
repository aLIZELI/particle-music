// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ParticleBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ParticleBar",
            path: "Sources/ParticleBar"
        )
    ]
)
