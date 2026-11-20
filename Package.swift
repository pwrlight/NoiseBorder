// swift-tools-version:5.9
import PackageDescription

// Тесты оформлены как исполняемая цель noise-check: в Command Line Tools нет XCTest и Swift Testing.
let package = Package(
    name: "NoiseBorder",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NoiseKit"),
        .executableTarget(name: "NoiseBorder", dependencies: ["NoiseKit"]),
        .executableTarget(name: "noise-render", dependencies: ["NoiseKit"]),
        .executableTarget(name: "noise-check", dependencies: ["NoiseKit"]),
    ]
)
