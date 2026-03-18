// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowsSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowsSwitcher", targets: ["WindowsSwitcher"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WindowsSwitcher",
            dependencies: [
                .product(name: "HotKey", package: "HotKey"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "WindowsSwitcherTests",
            dependencies: ["WindowsSwitcher"],
            path: "Tests"
        ),
    ]
)
