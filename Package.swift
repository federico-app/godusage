// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GodUsage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "GodUsage", targets: ["GodUsageApp"]),
        .executable(name: "godusage-cli", targets: ["GodUsageCLI"])
    ],
    dependencies: [
        // The de-facto standard recorder + global hotkey for Mac apps (System Settings-style field).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // In-app auto-updates (appcast + EdDSA-signed downloads). 2.9.4 fixes the update window opening
        // behind other apps for menu-bar (dockless) apps (sparkle-project/Sparkle#2889).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "GodUsage",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/GodUsage",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/pricing_supplement.json"),
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "GodUsageApp",
            dependencies: ["GodUsage"],
            path: "Sources/GodUsageApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "GodUsageCLI",
            dependencies: ["GodUsage"],
            path: "Sources/GodUsageCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GodUsageTests",
            dependencies: ["GodUsage"],
            path: "Tests/GodUsageTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GodUsageCLITests",
            dependencies: ["GodUsageCLI"],
            path: "Tests/GodUsageCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
