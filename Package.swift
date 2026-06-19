// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyricsOverlay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LyricsOverlay",
            path: "Sources/LyricsOverlay"
        ),
        .testTarget(
            name: "LyricsOverlayTests",
            dependencies: ["LyricsOverlay"],
            path: "Tests/LyricsOverlayTests"
        )
    ]
)
