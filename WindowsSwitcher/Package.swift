// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowsSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowsSwitcher", targets: ["WindowsSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "WindowsSwitcher",
            path: "Sources",
            exclude: [
                "WindowsSwitcher.entitlements",
                "Info.plist"
            ]
        ),
        .testTarget(
            name: "WindowsSwitcherTests",
            dependencies: ["WindowsSwitcher"],
            path: "Tests"
        ),
    ]
)
