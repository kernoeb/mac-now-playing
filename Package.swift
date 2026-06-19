// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacNowPlaying",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacNowPlaying",
            path: "Sources/MacNowPlaying"
        ),
        .testTarget(
            name: "MacNowPlayingTests",
            dependencies: ["MacNowPlaying"],
            path: "Tests/MacNowPlayingTests"
        )
    ]
)
