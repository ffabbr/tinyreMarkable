// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemarkableMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RemarkableMenuBar",
            path: "Sources/RemarkableMenuBar",
            resources: [
                .copy("Resources/rmapi")
            ]
        )
    ]
)
