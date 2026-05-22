// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tinyreMarkable",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tinyreMarkable",
            path: "Sources/tinyreMarkable",
            resources: [
                .copy("Resources/rmapi")
            ]
        )
    ]
)
