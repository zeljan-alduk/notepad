// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notepad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Notepad",
            path: "Sources/Notepad",
            resources: [.copy("Fonts"), .copy("AppIcon.icns")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        )
    ]
)
