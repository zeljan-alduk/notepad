// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FlashPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FlashPad",
            path: "Sources/FlashPad",
            resources: [.copy("Fonts"), .copy("AppIcon.icns")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        )
    ]
)
