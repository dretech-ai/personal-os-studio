// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PersonalOSStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PersonalOSStudio",
            path: "Sources/PersonalOSStudio"
        )
    ]
)
