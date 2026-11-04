// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PalaSync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PalaSync", path: "Sources/PalaSync")
    ]
)
